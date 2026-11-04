#!/usr/bin/env bash
#
# llm-cost.sh — estimate the electricity cost per token for the local
# llama.cpp servers by sampling GPU power draw and the servers' token
# counters, then print a paste-ready model_info block for the LiteLLM
# config (flux/apps/ai/litellm/litellm/files/config.yaml).
#
# Usage: ./llm-cost.sh [--rate 0.12215] [--baseline 50] [--seconds 60]
#                      [--idle-threshold 30] [--endpoints "9931 9932"]
#
#   --rate             $/kWh (default 0.12215 = Aug 2026 bill $217.43 / 1780 kWh)
#   --baseline         rest-of-system watts added to GPU draw (default 50)
#   --seconds          sampling window in seconds (default 60)
#   --idle-threshold   total GPU watts above which a sample is "active" (default 30)
#   --endpoints        space-separated llama.cpp server ports (default "9931 9932")
#
# Power sources:
#   AMD:    /sys/class/hwmon/hwmon*/power1_average (name=amdgpu, microwatts)
#   NVIDIA: nvidia-smi --query-gpu=power.draw (auto-detected, skipped if absent)
# Token counters: http://127.0.0.1:<port>/metrics
#   llamacpp:tokens_predicted_total   (generated tokens)
#   llamacpp:prompt_tokens_total      (prompt tokens, excludes cached)

set -euo pipefail

RATE="0.12215"
BASELINE=50
SAMPLE_SECONDS=60
IDLE_THRESHOLD=30
ENDPOINTS="9931 9932"

while [ $# -gt 0 ]; do
  case "$1" in
    --rate)           RATE="$2"; shift 2 ;;
    --baseline)       BASELINE="$2"; shift 2 ;;
    --seconds)        SAMPLE_SECONDS="$2"; shift 2 ;;
    --idle-threshold) IDLE_THRESHOLD="$2"; shift 2 ;;
    --endpoints)      ENDPOINTS="$2"; shift 2 ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

AMD_POWER_FILES=()
for c in /sys/class/hwmon/hwmon*; do
  if [ "$(cat "$c/name" 2>/dev/null || true)" = "amdgpu" ] && [ -r "$c/power1_average" ]; then
    AMD_POWER_FILES+=("$c/power1_average")
  fi
done

NVIDIA_OK=0
if command -v nvidia-smi >/dev/null 2>&1 && \
   nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits >/dev/null 2>&1; then
  NVIDIA_OK=1
fi

if [ ${#AMD_POWER_FILES[@]} -eq 0 ] && [ "$NVIDIA_OK" -ne 1 ]; then
  echo "error: no GPU power sensors found (no amdgpu hwmon, nvidia-smi unavailable)" >&2
  exit 1
fi

get_gpu_watts() {
  local total=0 f v nv
  for f in "${AMD_POWER_FILES[@]}"; do
    v=$(cat "$f" 2>/dev/null || echo 0)
    total=$(( total + v / 1000000 ))
  done
  if [ "$NVIDIA_OK" -eq 1 ]; then
    nv=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null \
          | awk '{ s += $1 } END { printf "%d", s + 0 }' || echo 0)
    total=$(( total + nv ))
  fi
  echo "$total"
}

get_counter() { # <port> <metric-suffix>
  curl -s --max-time 5 "http://127.0.0.1:$1/metrics" \
    | awk -v m="llamacpp:$2" '$1 == m { print $2 }' || true
}

echo "llm-cost: rate=$RATE \$/kWh  baseline=${BASELINE}W  window=${SAMPLE_SECONDS}s  idle-threshold=${IDLE_THRESHOLD}W"
echo "llm-cost: amd cards: ${#AMD_POWER_FILES[@]}  nvidia-smi: $NVIDIA_OK"

declare -A PRED_START PROMPT_START UP_PORTS
for port in $ENDPOINTS; do
  p=$(get_counter "$port" tokens_predicted_total)
  q=$(get_counter "$port" prompt_tokens_total)
  if [ -n "$p" ] && [ -n "$q" ]; then
    PRED_START[$port]=$p
    PROMPT_START[$port]=$q
    UP_PORTS[$port]=1
  else
    echo "llm-cost: :$port unreachable, skipping"
  fi
done

if [ ${#UP_PORTS[@]} -eq 0 ]; then
  echo "error: no llama.cpp server reachable" >&2
  exit 1
fi

echo "llm-cost: sampling for ${SAMPLE_SECONDS}s (generate some tokens for a good sample)..."
SPLITS=()
for (( i = 0; i < SAMPLE_SECONDS; i++ )); do
  SPLITS+=("$(get_gpu_watts)")
  sleep 1
done

ACTIVE_STATS=$(printf '%s\n' "${SPLITS[@]}" | awk -v t="$IDLE_THRESHOLD" '
  $1 > t { s += $1; n++ }
  { if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
  END { printf "%.1f %d %d %d", (n ? s / n : 0), n, min + 0, max + 0 }')
read -r ACTIVE_AVG ACTIVE_N MIN_W MAX_W <<< "$ACTIVE_STATS"

for port in $ENDPOINTS; do
  [ -n "${UP_PORTS[$port]:-}" ] || continue

  pred_end=$(get_counter "$port" tokens_predicted_total)
  prompt_end=$(get_counter "$port" prompt_tokens_total)
  d_pred=$(( pred_end - PRED_START[$port] ))
  d_prompt=$(( prompt_end - PROMPT_START[$port] ))

  awk -v port="$port" -v w="$ACTIVE_AVG" -v nact="$ACTIVE_N" -v minw="$MIN_W" -v maxw="$MAX_W" \
      -v b="$BASELINE" -v r="$RATE" -v dpred="$d_pred" -v dprompt="$d_prompt" -v s="$SAMPLE_SECONDS" 'BEGIN {
    outr  = dpred / s
    inr   = dprompt / s
    wt    = w + b
    ch    = wt / 1000 * r
    outc  = (outr  > 0) ? ch / (outr  * 3600) : 0
    inc   = (inr   > 0) ? ch / (inr   * 3600) : 0
    cachc = inc * 0.10

    printf "=== llama.cpp server :%s ===\n", port
    printf "  gpu power: active avg %s W (%d active samples, range %d-%d W)\n", w, nact, minw, maxw
    printf "  total with %d W baseline: %s W  ->  $%.4f/hour while active\n", b, wt, ch
    printf "  rates: output %.2f tok/s (%d tokens)  input %.2f tok/s (%d uncached prompt tokens)\n", outr, dpred, inr, dprompt
    if (nact == 0 || dpred == 0)
      printf "  WARNING: no active samples / output tokens in window - numbers unreliable, re-run under load\n"
    if (dprompt == 0)
      printf "  note: no uncached prompt tokens in window (heavy prompt cache) - input rate unreliable\n"
    printf "  per-Mtok: in $%.4f  out $%.4f  cached-in $%.5f\n", inc * 1e6, outc * 1e6, cachc * 1e6
    printf "\n  paste into flux/apps/ai/litellm/litellm/files/config.yaml:\n"
    printf "    model_info:\n"
    printf "      input_cost_per_token: %.12f\n", inc
    printf "      output_cost_per_token: %.12f\n", outc
    printf "      cache_read_input_token_cost: %.12f\n", cachc
  }'
  echo
done
