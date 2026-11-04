#!/usr/bin/env bash
#
# llm-cost.sh — estimate the electricity cost per token for the local LLM servers
# by sampling GPU power draw and the servers' token counters, then print a
# paste-ready model_info block for a LiteLLM gateway config.
#
# Usage: llm-cost.sh [--rate 0.12215] [--bill 217.43 --usage 1780] [--baseline 50]
#                    [--seconds 60] [--idle-threshold 30]
#                    [--endpoints "strata:8080 9931"] [--host 127.0.0.1]
#                    [--api-key KEY | --key-file FILE] [--cache-discount 0.10]
#                    [--format text,yaml,json] [--config FILE]
#                    [--hwmon-dir DIR] [--power-cmd CMD] [--curl-cmd CMD]
#
#   --rate             $/kWh (default 0.12215 = Aug 2026 bill $217.43 / 1780 kWh)
#   --bill / --usage   monthly bill and the kWh it bought; $/kWh = bill / usage
#   --baseline         rest-of-system watts added to GPU draw (default 50)
#   --seconds          sampling window in seconds (default 60)
#   --idle-threshold   total GPU watts above which a sample is "active" (default 30)
#   --endpoints        space-separated [engine:]port (default "8080 9931 9932")
#   --host             host the metrics endpoints live on (default 127.0.0.1)
#   --api-key KEY      Bearer token for authenticated /metrics/prometheus (Strata)
#   --key-file FILE    read that token from a file instead (mode 0600 recommended)
#   --cache-discount   cached prompt token cost as a fraction of a read one (default 0.10)
#   --format           comma-separated text,yaml,json (default text,yaml)
#   --config           config file (default ./llm-cost.conf, ~/.config/llm-cost/config)
#   --hwmon-dir        hwmon root directory (default /sys/class/hwmon)
#   --power-cmd CMD    command printing total GPU watts, replaces the sensors (tests)
#   --curl-cmd CMD     curl replacement (tests)
#
# Config precedence: flags > environment (LLM_COST_*) > config file > defaults.
# $STRATA_API_KEY is read as the bearer token when no --api-key / --key-file is given.
#
# Power sources:
#   AMD:    <hwmon-dir>/hwmon*/power1_average (name=amdgpu, microwatts)
#   NVIDIA: nvidia-smi --query-gpu=power.draw (auto-detected, skipped if absent)
#   both:   summed over cards, sampled once per second for the whole window
#
# Token counters (Prometheus text format):
#   llama.cpp: http://<host>:<port>/metrics                (no auth)
#   Strata:    http://<host>:<port>/metrics/prometheus     (Bearer token required)
#     llamacpp:tokens_predicted_total        generated tokens
#     llamacpp:prompt_tokens_total           prompt tokens read, excludes cached
#     llamacpp:prompt_tokens_cached_total    prompt tokens the cache held (Strata)
#     strata:gpu_power_watts                 the server's own view of GPU draw
#
# Run it on the machine that owns the GPU: the power sensors are local to it.

set -euo pipefail

RATE="0.12215"
BILL=""
USAGE=""
BASELINE=50
SAMPLE_SECONDS=60
IDLE_THRESHOLD=30
ENDPOINTS="8080 9931 9932"
TARGET_HOST="127.0.0.1"
API_KEY=""
KEY_FILE=""
CACHE_DISCOUNT="0.10"
FORMATS="text,yaml"
HWMON_DIR="/sys/class/hwmon"
POWER_CMD=""
CURL_CMD="curl"
SKIP_NVIDIA="${LLM_COST_SKIP_NVIDIA:-0}"

expand_path() { local v="$1"; printf '%s' "${v/#\~/$HOME}"; }
is_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
log() { printf '%s\n' "$*" >&2; }

# Settings arrive from three places; a later, higher level wins regardless of the
# order they are parsed in: config file (1) < environment (2) < flags (3).
declare -A SRC
apply_setting() { # <key> <value> <level>
  local key="$1" val="$2" level="$3" seen=0
  [ -z "${SRC[$key]+x}" ] || seen=1
  if [ "$seen" -eq 1 ] && [ "$level" -lt "${SRC[$key]}" ]; then return 0; fi
  SRC[$key]="$level"
  case "$key" in
    rate)           RATE="$2" ;;
    bill)           BILL="$2" ;;
    usage)          USAGE="$2" ;;
    baseline)       BASELINE="$2" ;;
    seconds|sample_seconds) SAMPLE_SECONDS="$2" ;;
    idle_threshold) IDLE_THRESHOLD="$2" ;;
    endpoints)      ENDPOINTS="$2" ;;
    host)           TARGET_HOST="$2" ;;
    cache_discount) CACHE_DISCOUNT="$2" ;;
    api_key)        API_KEY="$2" ;;
    key_file)       KEY_FILE="$(expand_path "$2")" ;;
    format)         FORMATS="$2" ;;
    hwmon_dir)      HWMON_DIR="$2" ;;
    *) return 0 ;;
  esac
}

load_config() { # <file>
  local file="$1" line key val
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "${line//[[:space:]]/}" ] || continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in \"*\") val="${val:1:${#val}-2}" ;; \'*\') val="${val:1:${#val}-2}" ;; esac
    apply_setting "$key" "$val" 1
  done < "$file"
}

for cfg in "${LLM_COST_CONFIG:-}" "./llm-cost.conf" "$(expand_path '~/.config/llm-cost/config')"; do
  if [ -n "$cfg" ] && [ -r "$cfg" ]; then load_config "$cfg"; break; fi
done

# --- environment ---------------------------------------------------------------
env_setting() { # <LLM_COST_NAME> <setting-key>
  local val="${2-}"
  [ -n "$val" ] || return 0
  apply_setting "$1" "$val" 2
}
apply_setting api_key        "${STRATA_API_KEY:-}"      2
apply_setting api_key        "${LLM_COST_API_KEY:-}"    2
env_setting rate             "${LLM_COST_RATE:-}"
env_setting bill             "${LLM_COST_BILL:-}"
env_setting usage            "${LLM_COST_USAGE:-}"
env_setting baseline         "${LLM_COST_BASELINE:-}"
env_setting seconds          "${LLM_COST_SECONDS:-}"
env_setting idle_threshold   "${LLM_COST_IDLE_THRESHOLD:-}"
env_setting endpoints        "${LLM_COST_ENDPOINTS:-}"
env_setting host             "${LLM_COST_HOST:-}"
env_setting cache_discount   "${LLM_COST_CACHE_DISCOUNT:-}"
env_setting key_file         "${LLM_COST_KEY_FILE:-}"
env_setting format           "${LLM_COST_FORMAT:-}"

# --- flags (win over env and config) -------------------------------------------
flag_setting() { apply_setting "$1" "$2" 3; }
while [ $# -gt 0 ]; do
  case "$1" in
    --rate)           flag_setting rate "$2"; shift 2 ;;
    --bill)           flag_setting bill "$2"; shift 2 ;;
    --usage)          flag_setting usage "$2"; shift 2 ;;
    --baseline)       flag_setting baseline "$2"; shift 2 ;;
    --seconds)        flag_setting seconds "$2"; shift 2 ;;
    --idle-threshold) flag_setting idle_threshold "$2"; shift 2 ;;
    --endpoints)      flag_setting endpoints "$2"; shift 2 ;;
    --host)           flag_setting host "$2"; shift 2 ;;
    --api-key)        flag_setting api_key "$2"; shift 2 ;;
    --key-file)       flag_setting key_file "$2"; shift 2 ;;
    --cache-discount) flag_setting cache_discount "$2"; shift 2 ;;
    --format)         flag_setting format "$2"; shift 2 ;;
    --config)         load_config "$(expand_path "$2")"; shift 2 ;;
    --hwmon-dir)      flag_setting hwmon_dir "$2"; shift 2 ;;
    --power-cmd)      POWER_CMD="$2"; shift 2 ;;
    --curl-cmd)       CURL_CMD="$2"; shift 2 ;;
    -h|--help)        awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if ! is_num "$RATE" || ! is_num "$BASELINE" || ! is_num "$CACHE_DISCOUNT" || \
   ! is_num "$SAMPLE_SECONDS" || ! is_num "$IDLE_THRESHOLD"; then
  echo "error: rate, baseline, cache-discount, seconds and idle-threshold must be non-negative numbers" >&2
  exit 2
fi
if [ -n "$BILL" ] && [ -n "$USAGE" ]; then
  if ! is_num "$BILL" || ! is_num "$USAGE"; then
    echo "error: --bill and --usage must be numbers" >&2; exit 2
  fi
  RATE=$(awk -v b="$BILL" -v u="$USAGE" 'BEGIN { if (u+0 <= 0) exit 1; printf "%.8f", b/u }') || \
    { echo "error: --usage must be greater than zero" >&2; exit 2; }
fi

WANT_TEXT=0; WANT_YAML=0; WANT_JSON=0
IFS=',' read -r -a FMT_LIST <<< "$FORMATS"
for f in "${FMT_LIST[@]}"; do
  case "${f//[[:space:]]/}" in
    text) WANT_TEXT=1 ;;
    yaml) WANT_YAML=1 ;;
    json) WANT_JSON=1 ;;
    "") ;;
    *) echo "error: unknown --format '$f' (text, yaml, json)" >&2; exit 2 ;;
  esac
done
if [ "$WANT_TEXT" -eq 0 ] && [ "$WANT_YAML" -eq 0 ] && [ "$WANT_JSON" -eq 0 ]; then
  echo "error: --format selected nothing" >&2; exit 2
fi

if [ -n "$KEY_FILE" ]; then
  if [ -r "$KEY_FILE" ]; then
    API_KEY=$(tr -d '\r\n' < "$KEY_FILE")
  elif [ -z "$API_KEY" ]; then
    echo "error: key file '$KEY_FILE' is not readable" >&2; exit 1
  fi
fi

JSON_TMP=$(mktemp)
trap 'rm -f "$JSON_TMP"' EXIT

# --- power sensors -------------------------------------------------------------
AMD_POWER_FILES=()
AMD_COUNT=0
for c in "$HWMON_DIR"/hwmon*; do
  if [ "$(cat "$c/name" 2>/dev/null || true)" = "amdgpu" ] && [ -r "$c/power1_average" ]; then
    AMD_POWER_FILES+=("$c/power1_average")
    AMD_COUNT=$(( AMD_COUNT + 1 ))
  fi
done

NVIDIA_OK=0
if [ "$SKIP_NVIDIA" != "1" ] && [ -z "$POWER_CMD" ] && \
   command -v nvidia-smi >/dev/null 2>&1 && \
   nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits >/dev/null 2>&1; then
  NVIDIA_OK=1
fi

if [ -z "$POWER_CMD" ] && [ "$AMD_COUNT" -eq 0 ] && [ "$NVIDIA_OK" -ne 1 ]; then
  log "error: no GPU power sensors found (no amdgpu hwmon under $HWMON_DIR, nvidia-smi unavailable)"
  log "       pass --power-cmd, --hwmon-dir, or LLM_COST_SKIP_NVIDIA=1 for tests"
  exit 1
fi

get_gpu_watts() {
  if [ -n "$POWER_CMD" ]; then
    local v
    v=$($POWER_CMD 2>/dev/null || echo 0)
    awk -v v="$v" 'BEGIN { printf "%d", v + 0 }'
    return
  fi
  local total=0 f v nv
  for f in ${AMD_POWER_FILES[@]+"${AMD_POWER_FILES[@]}"}; do
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

# --- metrics endpoints ---------------------------------------------------------
read -r -a CURL_ARGV <<< "$CURL_CMD"

http_get() { # <url> [bearer-token] — the token goes through stdin, never argv
  local url="$1" key="${2:-}"
  if [ -n "$key" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$key" \
      | "${CURL_ARGV[@]}" -s --max-time 5 --config - "$url" 2>/dev/null || true
  else
    "${CURL_ARGV[@]}" -s --max-time 5 "$url" 2>/dev/null || true
  fi
}

metrics_url() { # <port> <engine>
  if [ "$2" = "strata" ]; then
    printf 'http://%s:%s/metrics/prometheus' "$TARGET_HOST" "$1"
  else
    printf 'http://%s:%s/metrics' "$TARGET_HOST" "$1"
  fi
}

fetch_metrics() { # <port> <engine>
  local engine="$2" key=""
  [ "$engine" = "strata" ] && key="$API_KEY"
  http_get "$(metrics_url "$1" "$engine")" "$key"
}

has_metrics() { case "$1" in *"llamacpp:tokens_predicted_total"*) return 0 ;; *) return 1 ;; esac; }

counter() { # <body> <metric-name> -> value or empty
  awk -v m="$2" '$1 == m { v = $2 } END { if (v != "") print v }' <<<"$1"
}

gpu_watts_reported() { # <body> -> the server's own GPU watt sum, or empty
  awk '$1 ~ /^strata:gpu_power_watts(\{|[[:space:]])/ { s += $2; seen = 1 }
       END { if (seen) printf "%.1f", s }' <<<"$1"
}

declare -A START_BODY ENGINE MODEL AUTH_FAIL UP_PORTS START_PRED START_PROMPT START_CACHED START_WATTS
UP_COUNT=0

for spec in $ENDPOINTS; do
  eng=""; port=""
  case "$spec" in
    *:*) eng="${spec%%:*}"; port="${spec#*:}" ;;
    *)   port="$spec" ;;
  esac
  case "$eng" in
    "") ;;
    llama|llama.cpp|llamacpp) eng="llama" ;;
    strata) ;;
    *) log "llm-cost: endpoint '$spec': unknown engine '$eng', skipping"; continue ;;
  esac
  if ! is_num "$port"; then
    log "llm-cost: endpoint '$spec': not a port, skipping"; continue
  fi

  health=$(http_get "http://$TARGET_HOST:$port/health")
  guessed="$eng"
  if [ -z "$guessed" ]; then
    case "$health" in *'"service":"strata"'*|*'"service": "strata"'*) guessed="strata" ;; *) guessed="llama" ;; esac
  fi

  body=$(fetch_metrics "$port" "$guessed")
  if ! has_metrics "$body" && [ -z "$eng" ]; then
    other="strata"; [ "$guessed" = "strata" ] && other="llama"
    retried=$(fetch_metrics "$port" "$other")
    if has_metrics "$retried"; then body="$retried"; guessed="$other"; fi
  fi

  if ! has_metrics "$body"; then
    case "$body" in *authentication_error*)
      log "llm-cost: :$port reachable but unauthenticated (pass --api-key, --key-file or \$STRATA_API_KEY)"
    esac
    log "llm-cost: :$port has no llama.cpp-compatible /metrics, skipping"
    continue
  fi

  ENGINE[$port]="$guessed"
  UP_PORTS[$port]=1
  UP_COUNT=$(( UP_COUNT + 1 ))
  START_BODY[$port]="$body"
  case "$health" in *'"model"'*)
    MODEL[$port]=$(printf '%s' "$health" | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  esac
  START_PRED[$port]=$(counter "$body" "llamacpp:tokens_predicted_total")
  START_PROMPT[$port]=$(counter "$body" "llamacpp:prompt_tokens_total")
  START_CACHED[$port]=$(counter "$body" "llamacpp:prompt_tokens_cached_total")
  START_WATTS[$port]=$(gpu_watts_reported "$body")
done

if [ "$UP_COUNT" -eq 0 ]; then
  log "error: no llama.cpp-compatible /metrics endpoint reachable on: $ENDPOINTS"
  exit 1
fi

if [ -n "$BILL" ] && [ -n "$USAGE" ]; then
  log "llm-cost: rate=$RATE \$/kWh (bill \$$BILL / $USAGE kWh)  baseline=${BASELINE}W  window=${SAMPLE_SECONDS}s  idle-threshold=${IDLE_THRESHOLD}W"
else
  log "llm-cost: rate=$RATE \$/kWh  baseline=${BASELINE}W  window=${SAMPLE_SECONDS}s  idle-threshold=${IDLE_THRESHOLD}W"
fi
log "llm-cost: amd cards: $AMD_COUNT  nvidia-smi: $NVIDIA_OK  power: ${POWER_CMD:-sensors}"
for port in "${!UP_PORTS[@]}"; do
  label=":${port} engine=${ENGINE[$port]}"
  [ -n "${MODEL[$port]:-}" ] && label="$label model=${MODEL[$port]}"
  log "llm-cost: $label"
done

log "llm-cost: sampling for ${SAMPLE_SECONDS}s (generate some tokens for a good sample)..."
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
  port="${port#*:}"
  [ -n "${UP_PORTS[$port]:-}" ] || continue

  body=$(fetch_metrics "$port" "${ENGINE[$port]}")
  end_pred=$(counter "$body" "llamacpp:tokens_predicted_total")
  end_prompt=$(counter "$body" "llamacpp:prompt_tokens_total")
  end_cached=$(counter "$body" "llamacpp:prompt_tokens_cached_total")
  end_watts=$(gpu_watts_reported "$body")

  dpred=$(awk -v a="${START_PRED[$port]}" -v b="$end_pred" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.0f", d }')
  dprompt=$(awk -v a="${START_PROMPT[$port]}" -v b="$end_prompt" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.0f", d }')
  restarted=0
  if awk -v a="${START_PRED[$port]}" -v b="$end_pred" 'BEGIN { exit !(b+0 < a+0) }' || \
     awk -v a="${START_PROMPT[$port]}" -v b="$end_prompt" 'BEGIN { exit !(b+0 < a+0) }'; then
    restarted=1
  fi

  cache_known=0; dcached=0
  if [ -n "${START_CACHED[$port]:-}" ] && [ -n "$end_cached" ]; then
    cache_known=1
    dcached=$(awk -v a="${START_CACHED[$port]}" -v b="$end_cached" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.0f", d }')
  fi

  strata_watts="0"
  if [ "${ENGINE[$port]}" = "strata" ]; then
    strata_watts=$(awk -v a="${START_WATTS[$port]:-0}" -v b="${end_watts:-0}" 'BEGIN { printf "%.1f", (a+0 + b+0) / 2 }')
  fi

  awk -v port="$port" -v engine="${ENGINE[$port]}" -v model="${MODEL[$port]:-}" \
      -v w="$ACTIVE_AVG" -v nact="$ACTIVE_N" -v minw="$MIN_W" -v maxw="$MAX_W" \
      -v b="$BASELINE" -v r="$RATE" -v dpred="$dpred" -v dprompt="$dprompt" \
      -v dcached="$dcached" -v cache_known="$cache_known" -v restarted="$restarted" \
      -v strataw="$strata_watts" -v cd="$CACHE_DISCOUNT" -v s="$SAMPLE_SECONDS" \
      -v want_text="$WANT_TEXT" -v want_yaml="$WANT_YAML" -v want_json="$WANT_JSON" \
      -v jsonfile="$JSON_TMP" 'BEGIN {
    outr  = dpred / s
    inr   = dprompt / s
    wt    = w + b
    ch    = wt / 1000 * r
    outc  = (outr  > 0) ? ch / (outr  * 3600) : 0
    inc   = (inr   > 0) ? ch / (inr   * 3600) : 0
    cachc = inc * cd

    hitsum = dprompt + dcached
    hitr   = (cache_known && hitsum > 0) ? dcached / hitsum : -1
    blend  = (hitr >= 0) ? inc * (1 - hitr) : inc

    if (want_text) {
      head = (engine == "strata") ? "strata" : "llama.cpp"
      if (model != "") printf "=== %s server :%s (%s) ===\n", head, port, model
      else             printf "=== %s server :%s ===\n", head, port
      printf "  gpu power: active avg %s W (%d active samples, range %d-%d W)\n", w, nact, minw, maxw
      if (strataw + 0 > 0) {
        dev = (strataw > 0) ? (w - strataw) / strataw * 100 : 0
        printf "  cross-check: strata:gpu_power_watts %s W (%.1f%% vs hwmon)\n", strataw, dev
        if (dev > 30 || dev < -30)
          printf "  WARNING: hwmon and the server disagree on GPU watts by %.0f%% - check the sensor\n", dev
      }
      printf "  total with %d W baseline: %s W  ->  $%.4f/hour while active\n", b, wt, ch
      printf "  rates: output %.2f tok/s (%d tokens)  input %.2f tok/s (%d uncached prompt tokens)\n", outr, dpred, inr, dprompt
      if (cache_known) {
        printf "  cache: %d cached / %d read prompt tokens (%.1f%% hit)\n", dcached, dprompt, hitr * 100
      } else {
        printf "  cache: this server does not expose a cached-token counter\n"
      }
      if (restarted)
        printf "  WARNING: counters went down during the window - the server restarted, numbers unreliable\n"
      if (nact == 0 || dpred == 0)
        printf "  WARNING: no active samples / output tokens in window - numbers unreliable, re-run under load\n"
      if (dprompt == 0)
        printf "  note: no uncached prompt tokens in window (heavy prompt cache) - input rate unreliable\n"
      printf "  per-Mtok: in $%.4f  out $%.4f  cached-in $%.5f (assumed %d%% of read)\n", \
             inc * 1e6, outc * 1e6, cachc * 1e6, cd * 100
      if (cache_known && hitsum > 0)
        printf "  effective blended input price at this hit rate: $%.4f /Mtok\n", blend * 1e6
    }

    if (want_yaml) {
      printf "  paste into LiteLLM model_info:\n"
      printf "    model_info:\n"
      printf "      input_cost_per_token: %.12f\n", inc
      printf "      output_cost_per_token: %.12f\n", outc
      printf "      cache_read_input_token_cost: %.12f\n", cachc
    }

    if (want_json) {
      m = model; gsub(/\\/, "\\\\", m); gsub(/"/, "\\\"", m)
      warns = ""
      if (restarted)      warns = warns (warns == "" ? "" : ",") "\"restarted\""
      if (nact == 0)      warns = warns (warns == "" ? "" : ",") "\"no-active-samples\""
      if (dpred == 0)     warns = warns (warns == "" ? "" : ",") "\"no-output-tokens\""
      if (dprompt == 0)   warns = warns (warns == "" ? "" : ",") "\"no-uncached-prompt-tokens\""
      printf "{" > jsonfile
      printf "\"endpoint\":\"%s\",", port > jsonfile
      printf "\"engine\":\"%s\",", engine > jsonfile
      printf "\"model\":\"%s\",", m > jsonfile
      printf "\"window_seconds\":%s,", s > jsonfile
      printf "\"rate_per_kwh\":%s,", r > jsonfile
      printf "\"baseline_watts\":%s,", b > jsonfile
      printf "\"gpu_active_avg_watts\":%s,", w > jsonfile
      printf "\"gpu_active_samples\":%d,", nact > jsonfile
      printf "\"gpu_min_watts\":%d,", minw > jsonfile
      printf "\"gpu_max_watts\":%d,", maxw > jsonfile
      printf "\"server_reported_gpu_watts\":%s,", strataw + 0 > jsonfile
      printf "\"total_watts\":%.1f,", wt > jsonfile
      printf "\"cost_per_hour\":%.6f,", ch > jsonfile
      printf "\"output_tokens\":%d,", dpred > jsonfile
      printf "\"input_tokens\":%d,", dprompt > jsonfile
      printf "\"cached_tokens\":%s,", (cache_known ? dcached : "null") > jsonfile
      printf "\"cache_hit_rate\":%s,", (hitr >= 0 ? sprintf("%.4f", hitr) : "null") > jsonfile
      printf "\"output_tokens_per_second\":%.4f,", outr > jsonfile
      printf "\"input_tokens_per_second\":%.4f,", inr > jsonfile
      printf "\"input_cost_per_token\":%.12f,", inc > jsonfile
      printf "\"output_cost_per_token\":%.12f,", outc > jsonfile
      printf "\"cache_read_input_token_cost\":%.12f,", cachc > jsonfile
      printf "\"blended_input_cost_per_token\":%.12f,", blend > jsonfile
      printf "\"warnings\":[%s]", warns > jsonfile
      printf "}\n" > jsonfile
    }
  }'
  [ $(( WANT_TEXT + WANT_YAML )) -gt 0 ] && echo
done

if [ "$WANT_JSON" -eq 1 ]; then
  json_array=$(awk 'NR > 1 { printf ",\n" } { printf "%s", $0 }' "$JSON_TMP")
  if [ $(( WANT_TEXT + WANT_YAML )) -eq 0 ]; then
    printf '[\n%s\n]\n' "$json_array"
  else
    echo "=== json ==="
    printf '[\n%s\n]\n' "$json_array"
  fi
fi
