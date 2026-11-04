# local-llm-cost-calculator

Estimate the electricity cost per token of your own local LLM inference, and print a
paste-ready `model_info:` block for a LiteLLM gateway config.

The tool samples **GPU power draw** from the machine's own sensors while the inference
server generates tokens, reads the server's **token counters**, and divides one by the
other. Nothing is estimated from vendor benchmarks: you pay for the watts your card
actually drew.

Two engines are supported, auto-detected per endpoint:

| Engine | Endpoint | Auth |
| ------ | -------- | ---- |
| llama.cpp (`llama-server`) | `GET /metrics` | none |
| Strata (`strata --serve`) | `GET /metrics/prometheus` | `Authorization: Bearer <api key>` |

Strata serves its counters under llama.cpp's metric names, so the same maths works for
both. See [docs/metrics.md](docs/metrics.md) for the counter-by-counter details.

## Requirements

Run it **on the machine that hosts the GPU** — the power sensors are local to it
(`/sys/class/hwmon/hwmon*/power1_average` for AMD, `nvidia-smi` for NVIDIA), and the
default endpoint host is `127.0.0.1`.

- bash 5+, `curl`, `awk` (mawk/gawk/busybox all fine)
- No Python, no jq, no other runtime dependencies.

## Usage

```bash
bin/llm-cost.sh --seconds 120 --endpoints "strata:8080 9931 9932"
```

Then generate tokens in another window (a long completion, an agent run, a benchmark).
The sample is only as good as the load you put through it.

```
llm-cost: rate=0.12215 $/kWh  baseline=50W  window=120s  idle-threshold=30W
llm-cost: amd cards: 1  nvidia-smi: 1  power: sensors
llm-cost: :8080 engine=strata model=qwen3.8-flash-next-iq3_s
llm-cost: :9931 has no llama.cpp-compatible /metrics, skipping
llm-cost: sampling for 120s (generate some tokens for a good sample)...

=== strata server :8080 (qwen3.8-flash-next-iq3_s) ===
  gpu power: active avg 218.4 W (87 active samples, range 24-241 W)
  cross-check: strata:gpu_power_watts 214.9 W (1.6% vs hwmon)
  total with 50 W baseline: 268.4 W  ->  $0.0328/hour while active
  rates: output 21.35 tok/s (2562 tokens)  input 96.10 tok/s (11532 uncached prompt tokens)
  cache: 52110 cached / 11532 read prompt tokens (81.9% hit)
  per-Mtok: in $10.2431  out $3.6140  cached-in $1.02431 (assumed 10% of read)
  effective blended input price at this hit rate: $1.8541 /Mtok
  paste into LiteLLM model_info:
    model_info:
      input_cost_per_token: 0.0000102431
      output_cost_per_token: 0.0000036140
      cache_read_input_token_cost: 0.0000010243
```

Progress and diagnostics go to **stderr**, results to **stdout**, so
`--format json` alone gives a clean JSON array you can pipe to `jq`.

### Flags

| Flag | Default | Purpose |
| ---- | ------- | ------- |
| `--rate 0.12215` | `0.12215` | `$/kWh` |
| `--bill 217.43 --usage 1780` | — | Derive `$/kWh` from a monthly bill and kWh consumed (overrides `--rate`) |
| `--baseline 50` | `50` | Watts added for the rest of the system (CPU, RAM, fans, PSU loss) |
| `--seconds 60` | `60` | Sampling window |
| `--idle-threshold 30` | `30` | Total GPU watts above which a 1 s sample counts as "active" |
| `--endpoints "8080 9931"` | `8080 9931 9932` | Space-separated endpoints; optional `engine:` prefix (`strata:8080`, `llama:9931`), bare port is auto-detected |
| `--host 127.0.0.1` | `127.0.0.1` | Host the metrics endpoints live on |
| `--api-key`, `--key-file`, `$STRATA_API_KEY` | — | Bearer token for authenticated `/metrics/prometheus` (Strata) |
| `--cache-discount 0.10` | `0.10` | Assumed cost of a cached prompt token as a fraction of a read one |
| `--format text,yaml,json` | `text,yaml` | Output formats; `json` emits one object per endpoint on stdout |
| `--config FILE` | auto | Config file (see below) |
| `--hwmon-dir`, `--curl-cmd` | system | Test hooks: point at a fake hwmon tree / stub curl |

Precedence: **flags > environment (`LLM_COST_*`) > config file > built-in defaults.**
That holds for a config file named with `--config` too: its *contents* sit at the file
level, only the choice of file is a flag.

## Config file

Copy `llm-cost.conf.example` to `./llm-cost.conf`, or
`${XDG_CONFIG_HOME:-~/.config}/llm-cost/config`. Every key matches a flag name
upper-cased (`rate`, `baseline`, `endpoints`, `cache_discount`, `api_key`, ...).
Keep the Strata key in a `--key-file` (mode 0600) rather than in a config file that
ends up in git.

## LiteLLM output

The `yaml` block is meant for a LiteLLM gateway's per-model config:

```yaml
model_info:
  input_cost_per_token: 0.0000102431
  output_cost_per_token: 0.0000036140
  cache_read_input_token_cost: 0.0000010243
```

`docs/litellm-snippet.yaml` is the currently applied block for `qwen3.8-flash-next`
on this network, with the sample it came from and how to re-measure it.

## Applying the numbers

LiteLLM's `*_cost_per_token` fields are dollars **per token** — paste them as printed.
opencode's `provider.<name>.models.<model>.cost` fields are dollars **per million
tokens**, so multiply by 1e6:

```jsonc
"qwen3.8-flash-next": {
  "cost": { "input": 0.042134, "output": 0.902435,
            "cache_read": 0.004213, "cache_write": 0.042134 },
  "limit": { "context": 262144, "output": 32000 }
}
```

Cost per token follows the traffic mix: a prefill-heavy window spends its watts while
generating few output tokens, so the same GPU measures output at ~$0.90/Mtok under
agent-shaped load and ~$0.17/Mtok under decode-shaped load. Sample the load you
actually serve.

## Deploy to the inference host

The repo is the source of truth; the inference box just runs the script.

```bash
make install HOST=paul@192.168.30.225 DEST=~/llama-server
```

That rsyncs `bin/llm-cost.sh` to the host as `llm-cost.sh`. Nothing runs on the remote
side, and the host's existing script is only replaced if you say so.

## Tests

```bash
make test        # zero-dependency bash runner, uses fixtures + --hwmon-dir/--curl-cmd
make lint        # shellcheck, if installed
```

The Makefile is convenience only (GNU make is on the inference host, not on every
laptop): `make test` is `bash tests/run.sh`, and `make install` is one `rsync`.

## Caveats

- Cached prompt tokens still cost energy (attention over the cache), but the counters
  do not separate that work from the rest of the request, so
  `cache_read_input_token_cost` stays an assumption (`--cache-discount`). The measured
  cache hit rate and the blended effective input price are reported so you can see how
  much that assumption is worth.
- A server restart inside the window resets its counters; the delta is clamped to zero
  and the endpoint is reported as restarted rather than billing a negative cost.
- A heavy prompt cache can leave the window with almost no uncached prompt tokens; the
  input price is then marked unreliable.

## History

`legacy/llm-cost-2026-09.sh` is the original single-engine (llama.cpp, containerised)
script byte-for-byte, as it ran on the inference host. This repo is a rewrite of it.
