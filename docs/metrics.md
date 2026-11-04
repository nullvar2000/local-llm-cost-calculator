# Counters and sensors

What the tool reads, and what each number actually means.

## Endpoints

| Engine | URL | Auth |
| ------ | --- | ---- |
| llama.cpp | `http://<host>:<port>/metrics` | none |
| Strata | `http://<host>:<port>/metrics/prometheus` | `Authorization: Bearer <api key>` (a separate `telemetry_key` is accepted by Strata too) |

Liveness/engine probe: `GET /health`. Strata answers
`{"status":"ok","model":"...","service":"strata","api_key":true,...}`; llama.cpp answers
a bare `{}` or 404 on some builds, so the probe is a hint and the metric fetch is the
decision.

Without a key, Strata returns `{"error":{"type":"authentication_error",...}}` with 401 —
the tool reports that as *reachable but unauthenticated* instead of silently skipping the
endpoint.

## Token counters

Both engines expose the llama.cpp names. Strata does this deliberately, so llama.cpp
dashboards work unchanged against it.

| Metric | llama.cpp | Strata |
| ------ | --------- | ------ |
| `llamacpp:tokens_predicted_total` | tokens generated | same |
| `llamacpp:prompt_tokens_total` | prompt tokens processed | prompt tokens **read**, i.e. lifetime total minus cache reuse |
| `llamacpp:prompt_tokens_cached_total` | build-dependent (check your build) | prompt tokens the conversation cache already held |
| `llamacpp:prompt_seconds_total` | prompt read time | same |
| `llamacpp:tokens_predicted_seconds_total` | generation time | same |
| `llamacpp:requests_processing` / `llamacpp:requests_deferred` | gauges | same |
| `llamacpp:prompt_tokens_seconds` / `llamacpp:predicted_tokens_seconds` | lifetime-average gauges | averaged over the window between two scrapes |

The two `*_seconds` gauges are averages, not instantaneous throughput, and their meaning
differs between engines — the tool never uses them, it always differences the `*_total`
counters across its own window.

Strata additionally serves vLLM-named families (`vllm:generation_tokens_total`,
`vllm:prefix_cache_hits_total`, `vllm:spec_decode_num_*_total`, latency histograms) and
its own (`strata:requests_total`, `strata:drafts_*`). None of these are needed for cost:
the llama.cpp-named counters already separate read from cached prompt tokens.

`prompt_tokens_total` excluding cached tokens is what makes the input price honest: a
token that came from the cache was not read, so it must not be divided into the read
cost. The flip side is that cached reads get no measured cost at all — see the caveat
below.

## Hardware counters

| Source | Read as |
| ------ | ------- |
| `/sys/class/hwmon/hwmon*/power1_average` where `name` is `amdgpu` | microwatts → watts, summed over cards |
| `nvidia-smi --query-gpu=power.draw` | watts, summed over cards |
| `strata:gpu_power_watts{gpu="N"}` | watts as reported by the server itself |

The first two are sampled every second for the whole window. The third is read at the
start and end of the window only, as a cross-check: if the server's own view of the card
disagrees with hwmon by more than 30%, one of them is lying and the run prints a warning.

hwmon is preferred because it costs nothing, covers the whole card (including the parts
the engine cannot see), and works for engines that expose no telemetry at all.

## Cost model

```
active_avg   = mean of the 1 s power samples above --idle-threshold
total_watts  = active_avg + --baseline
cost_per_hour = total_watts / 1000 * --rate          # $/h while the GPU is busy
out_rate     = Δ tokens_predicted_total / window_seconds
in_rate      = Δ prompt_tokens_total    / window_seconds      # uncached only
output_cost  = cost_per_hour / (out_rate * 3600)     # $/token
input_cost   = cost_per_hour / (in_rate  * 3600)     # $/token
cached_cost  = input_cost * --cache-discount
```

Baseline watts cover everything that burns energy while inference runs but is not in the
GPU sensors: CPU spinning on the sampler and the tokeniser, system RAM, drives, fans, and
PSU conversion loss.

### Why `cache_read_input_token_cost` is an assumption

A cached prompt token still costs energy — the request attends over the cached KV, and
the cache occupies VRAM that limits batching. But neither engine emits a counter for
"energy spent on cache reads", and Strata's `prompt_seconds_total` deliberately excludes
cached tokens from the read time, so there is nothing to difference. `--cache-discount`
therefore stays a policy input (10% by default, matching the common LiteLLM convention).

What the tool *does* measure is the hit rate: `cached / (cached + read)` from the two
counters. That turns the assumption into a visible, bounded decision — at an 82% hit
rate, a 10%-vs-25% discount moves your blended input price by a few hundredths of a
dollar per Mtok, so the run prints the blended number to let you judge it.

### Restart and reset handling

Counters reset on server restart. A negative delta is clamped to 0, the endpoint is
flagged as restarted mid-window, and its rates are marked unreliable rather than
reporting a negative price.
