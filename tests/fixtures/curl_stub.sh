#!/usr/bin/env bash
# Fake curl for the tests: answers each URL with a canned fixture, and serves the
# "start" fixture on the first metrics call and the "end" fixture afterwards, so a
# whole sampling window runs with no network and no server.
#
#   LLM_COST_TEST_STUB  which fixture set to serve (strata, llama, authfail, reset)
#   LLM_COST_TEST_STATE call-counter file (the runner points this at a scratch dir)
set -u

fx="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${LLM_COST_TEST_STUB:-strata}"

url=""
for a in "$@"; do
  case "$a" in http*) url="$a" ;; esac
done
[ -n "$url" ] || exit 1

case "$url" in
  */health)
    f="$fx/health_${mode}.json"
    if [ -f "$f" ]; then cat "$f"; else printf '{}'; fi
    ;;
  */metrics/prometheus|*/metrics)
    n=0
    if [ -n "${LLM_COST_TEST_STATE:-}" ]; then
      [ -f "$LLM_COST_TEST_STATE" ] && n=$(cat "$LLM_COST_TEST_STATE")
      n=$(( n + 1 ))
      printf '%s' "$n" > "$LLM_COST_TEST_STATE"
    fi
    if [ "$n" -le 1 ]; then tag=start; else tag=end; fi
    f="$fx/${mode}.${tag}.txt"
    if [ -f "$f" ]; then cat "$f"; else printf 'no metrics here\n'; fi
    ;;
  *)
    printf ''
    ;;
esac
