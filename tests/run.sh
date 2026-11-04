#!/usr/bin/env bash
# Zero-dependency test runner: no bats, no network, no root, no GPU.
#
# The tool is exercised through its two test seams (--curl-cmd, --power-cmd /
# --hwmon-dir) against the canned fixtures in tests/fixtures.
#
#   bash tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/llm-cost.sh"
FX="$ROOT/tests/fixtures"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
TEST=""
out=""
status=0

ok()  { pass=$(( pass + 1 )); printf '       ok   %s\n' "$1"; }
bad() { fail=$(( fail + 1 )); printf '       FAIL %s\n' "$1"; printf '            in: %s\n' "$TEST"; }
has()    { case "$out" in *"$1"*) ok "found: $1" ;; *) bad "missing: $1" ;; esac; }
hasnt()  { case "$out" in *"$1"*) bad "unexpected: $1" ;; *) ok "absent: $1" ;; esac; }
exit_is(){ [ "$status" -eq "$1" ] && ok "exit $1" || bad "exit $1 (got $status)" ; }

# One sampling run against the stub. Two samples: the counters differ between the
# start and end fixtures, so the deltas are what the assertions check.
invoke() { # <stub-mode> [tool args...]
  local stub="$1"; shift
  rm -f "$SCRATCH/state"
  ( LLM_COST_TEST_STUB="$stub" LLM_COST_TEST_STATE="$SCRATCH/state" \
    LLM_COST_SKIP_NVIDIA=1 LLM_COST_TEST_WATTS="${TEST_WATTS:-200}" \
    "$BIN" --curl-cmd "$FX/curl_stub.sh" --power-cmd "bash $FX/power_flat.sh" \
           --seconds 1 "$@" )
}

printf 'engine detection and happy paths\n'

TEST="strata: detected from /health, priced from the counters"
out=$(invoke strata --endpoints "8080" --rate 0.10 --baseline 50 --cache-discount 0.10 \
             --format text,yaml,json 2>&1); status=$?
exit_is 0
has 'engine=strata model=qwen3.8-flash-next-iq3_s'
has 'gpu power: active avg 200.0 W (1 active samples, range 200-200 W)'
has 'total with 50 W baseline: 250 W  ->  $0.0250/hour while active'
# 250 W at $0.10/kWh = $0.025/h. 1000 generated + 10000 uncached prompt tokens in 1 s:
# out 1000 tok/s -> 0.025 / (1000*3600) = 6.944e-9/tok; in 10000 tok/s -> 6.944e-10/tok.
has 'input_cost_per_token: 0.000000000694'
has 'output_cost_per_token: 0.000000006944'
has 'cache_read_input_token_cost: 0.000000000069'
has 'rates: output 1000.00 tok/s (1000 tokens)  input 10000.00 tok/s (10000 uncached prompt tokens)'
has 'cache: 8000 cached / 10000 read prompt tokens (44.4% hit)'
has 'effective blended input price at this hit rate: $0.0004 /Mtok'
has 'cross-check: strata:gpu_power_watts 220.0 W (-9.1% vs hwmon)'
hasnt 'WARNING'
has '"engine":"strata"'
has '"cached_tokens":8000'
has '"cache_hit_rate":0.4444'
has '"cost_per_hour":0.025000'

TEST="explicit strata: endpoint prefix"
out=$(invoke strata --endpoints "strata:8080" --rate 0.10 --baseline 50 --format yaml 2>&1); status=$?
exit_is 0
has 'input_cost_per_token: 0.000000000694'

TEST="llama.cpp endpoint: /metrics, no cached counter, no cross-check"
out=$(invoke llama --endpoints "9931" --rate 0.10 --baseline 50 --format text,yaml 2>&1); status=$?
exit_is 0
has '=== llama.cpp server :9931 ==='
has 'cache: this server does not expose a cached-token counter'
hasnt 'cross-check'
# 1000 prompt and 100 generated tokens in 1 s at 250 W / $0.10:
has 'input_cost_per_token: 0.000000006944'
has 'output_cost_per_token: 0.000000069444'

printf 'failure and edge paths\n'

TEST="counters reset mid-window is flagged, not billed"
out=$(invoke reset --endpoints "8080" --rate 0.10 --baseline 50 --format text,yaml 2>&1); status=$?
exit_is 0
has 'WARNING: counters went down during the window - the server restarted, numbers unreliable'
has 'input_cost_per_token: 0.000000000000'
has 'output_cost_per_token: 0.000000000000'
hasnt 'input_cost_per_token: -'

TEST="authenticated endpoint without a key"
out=$(invoke authfail --endpoints "8080" --format text 2>&1); status=$?
exit_is 1
has ':8080 reachable but unauthenticated'
has 'no llama.cpp-compatible /metrics endpoint reachable'

TEST="endpoint that answers no metrics"
out=$(invoke none --endpoints "9999" --format text 2>&1); status=$?
exit_is 1
has 'has no llama.cpp-compatible /metrics, skipping'
has 'no llama.cpp-compatible /metrics endpoint reachable'

TEST="endpoint with an unknown engine prefix"
out=$(invoke strata --endpoints "bogus:8080" --format text 2>&1); status=$?
exit_is 1
has "unknown engine 'bogus'"

printf 'sensors\n'

TEST="amdgpu hwmon sensor is found by name and read in microwatts"
out=$(LLM_COST_SKIP_NVIDIA=1 LLM_COST_TEST_STUB=strata LLM_COST_TEST_STATE="$SCRATCH/state2" \
      "$BIN" --curl-cmd "$FX/curl_stub.sh" --hwmon-dir "$FX/hwmon" --seconds 1 \
             --endpoints "8080" --rate 0.10 --format text 2>&1); status=$?
exit_is 0
has 'amd cards: 1  nvidia-smi: 0'
has 'gpu power: active avg 218.0 W'
has 'total with 50 W baseline: 268 W'

TEST="no sensors at all"
out=$(LLM_COST_SKIP_NVIDIA=1 "$BIN" --hwmon-dir "$SCRATCH/empty" --seconds 1 2>&1); status=$?
exit_is 1
has 'no GPU power sensors found'

printf 'configuration\n'

TEST="bill and usage derive the rate"
out=$(invoke strata --endpoints "8080" --bill 217.43 --usage 1780 --format text 2>&1); status=$?
exit_is 0
has 'rate=0.12215169 $/kWh (bill $217.43 / 1780 kWh)'

TEST="config file feeds defaults"
cfg="$SCRATCH/llm-cost.conf"
printf 'baseline=77\nrate=0.5\nendpoints=strata:8080\nformat=text\n' > "$cfg"
out=$(invoke strata --config "$cfg" 2>&1); status=$?
exit_is 0
has 'rate=0.5 $/kWh  baseline=77W'

TEST="flags override the config file"
out=$(invoke strata --config "$cfg" --baseline 90 --rate 0.25 2>&1); status=$?
exit_is 0
has 'rate=0.25 $/kWh  baseline=90W'

TEST="environment overrides the config file, flags override the environment"
out=$(LLM_COST_BASELINE=66 invoke strata --config "$cfg" --baseline 91 2>&1); status=$?
exit_is 0
has 'baseline=91W'
hasnt 'baseline=66W'
out=$(LLM_COST_BASELINE=66 invoke strata --config "$cfg" 2>&1); status=$?
has 'baseline=66W'

printf 'output formats and CLI\n'

TEST="--format json is pure JSON on stdout"
out=$(invoke strata --endpoints "8080" --rate 0.10 --format json 2>/dev/null); status=$?
exit_is 0
case "$out" in
  \[*) ok "starts with [" ;;
  *)   bad "json output does not start with [ : $out" ;;
esac
case "$out" in
  *]) ok "ends with ]" ;;
  *)  bad "json output does not end with ]" ;;
esac
hasnt 'llm-cost:'
hasnt 'model_info:'
has '"output_cost_per_token":0.000000006944'
has '"warnings":[]'
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$out" | jq -e '.[0].engine == "strata"' >/dev/null 2>&1; then
    ok "jq parses the array and sees engine=strata"
  else
    bad "jq could not parse the json output"
  fi
else
  ok "jq not installed, skipping the parse check"
fi

TEST="progress lines go to stderr, results to stdout"
out=$(invoke strata --endpoints "8080" --rate 0.10 --format text,yaml 2>/dev/null); status=$?
exit_is 0
hasnt 'llm-cost: sampling'
has 'model_info:'

TEST="--help"
out=$("$BIN" --help 2>&1); status=$?
exit_is 0
has '--cache-discount'
has '--key-file'
hasnt '/usr/bin/env bash'
hasnt 'Settings arrive from three places'

TEST="unknown option"
out=$("$BIN" --nope 2>&1); status=$?
exit_is 2
has 'unknown option'

TEST="unknown format"
out=$("$BIN" --format toml 2>&1); status=$?
exit_is 2
has "unknown --format 'toml'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
