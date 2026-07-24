<!-- Copyright 2026 Alibaba Cloud

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. -->

# Tokenless Benchmark Suite

Reproducible benchmark, quality, and cost-analysis suite for the tokenless
compression engine (schema compression, response compression, TOON encoding,
RTK rewrite compatibility). Rebuilt to match the V5 benchmark reports.

This is a **standalone Cargo workspace** (see `Cargo.toml`) so it does not
inherit the main tokenless `panic = "abort"` profile (which breaks criterion)
and does not pull benchmark-only deps into the main `cargo test --workspace`.
It depends on the tokenless crates by path.

> tokenless is Linux-only. Build and run this on Linux.

## Layout

```
benchmarks/
├── fixtures/                     # canonical inputs (generated, committed)
│   ├── records.json              #   1000 uniform records
│   ├── tool_response.json        #   canonical response payload
│   └── schema_search.json        #   canonical function schema
├── src/lib.rs                    # payload generators; loads fixtures for canonical inputs
├── src/metrics.rs                # in-process compression-rate measurement + cost analysis
├── src/bin/compression_rate.rs   # prints/emits the rate report (--json)
├── benches/                      # performance (criterion, 5 files)
│   ├── schema_latency.rs         #  10 measurements (incl. canonical)
│   ├── response_latency.rs       #  15 measurements (incl. canonical)
│   ├── toon_latency.rs           #  15 measurements (encode/decode/roundtrip + canonical)
│   ├── pipeline_latency.rs       #   7 measurements (stacked in-process)
│   └── rtk_latency.rs            #   7 measurements (subprocess, ms-scale)
├── tests/                        # quality (5) + adversarial (3) + rate guards
│   ├── schema_retention.rs       #   8 tests
│   ├── response_retention.rs     #  11 tests
│   ├── toon_roundtrip.rs         #   8 tests
│   ├── rtk_format_compat.rs      #   9 tests (skip if rtk absent)
│   ├── pipeline_retention.rs     #   6 tests (end-to-end field retention)
│   ├── adversarial_schema.rs     #  14 tests
│   ├── adversarial_response.rs   #  16 tests
│   ├── adversarial_toon.rs       #  10 tests
│   ├── worst_case.rs             #   9 tests
│   └── compression_rate.rs       #   5 rate-regression guards
├── python/                       # fixture generation
│   ├── gen_fixtures.py           #   single source of truth for input data
│   └── requirements.txt          #   Python dependencies for gen_fixtures.py
└── run-benchmarks.sh             # orchestrator script
```

## Prerequisites

- Rust stable (edition 2024, >= 1.85)
- `rtk` binary for `rtk_format_compat.rs` (optional — tests skip if missing).
  Build it from the tokenless tree: `just setup-rtk && cargo build --release
  --manifest-path third_party/rtk/Cargo.toml`, then point tests at it with
  `RTK_BIN=/path/to/rtk` or place it at `../third_party/rtk/target/release/rtk`.
- Python 3.11+ and `pip install -r python/requirements.txt` for fixture regeneration only
  (fixtures are committed; Python is NOT required for benchmarks or tests).

## Running

```bash
# Everything (build + tests + benches + compression rate report):
./run-benchmarks.sh

# Fast path (no criterion benches):
./run-benchmarks.sh --quick

# Individually:
cargo test --release                          # quality + adversarial + rate guards (96 tests)
cargo bench                                   # performance (criterion, 54 benchmark points)
cargo run --release --bin compression_rate    # in-process compression rates + cost analysis
cargo run --release --bin compression_rate -- --json  # machine-readable JSON output
```

Note: `run-benchmarks.sh` calls `cargo run --release --bin compression_rate` for
the rate/cost report (no Python dependency). All post-processing (cost model,
stacking report) is computed in Rust in-process.

## Methodology

- **Token counting**: `(bytes + 3) / 4` (div_ceil) — identical to the engine's
  own `estimate_tokens_from_bytes` heuristic. Not a real tokenizer; exists only
  for consistent in-suite comparison.
- **Criterion**: runs 100 samples per benchmark (RTK benchmarks use 20 due to
  subprocess overhead). For report-grade numbers, recommended practice is 3 runs
  taking median average (not mandatory).
- Latency benches construct the compressor **once** (outside the timed closure)
  and reuse it; only the `compress()` / encode call is measured. Compressor
  setup and teardown are **excluded** so the figures line up with headroom,
  which likewise does not count startup/teardown time.
- **Single input source.** `python/gen_fixtures.py` is the one generator for all
  benchmark data; it writes `fixtures/*.json`. The Rust benches embed these via
  `include_str!` and use the same files, so latency and compression rate are
  measured on **byte-identical** payloads. The `canonical` bench point in
  `response_latency`/`schema_latency` compresses exactly the payload whose
  compression rate the `compression_rate` binary reports — the two numbers are
  attributable to one input. Regenerate with `python3 python/gen_fixtures.py`
  (fixtures are committed; no need to run it before building).
- **Compression rate is measured in Rust, in-process.** `src/metrics.rs` counts
  tokens (bytes/4, same heuristic as the engine) immediately before and after
  each compressor call — no CLI subprocess in the measurement loop — and
  `tests/compression_rate.rs` pins the rates as regression guards, so any
  compression change is traceable to a commit via `cargo test`. The
  `compression_rate` binary emits the full report including cost analysis
  (`--json` for machine-readable output).

## Known Limitations

1. **Single canonical fixture**: Compression rates measured on one synthetic fixture per compressor.
   Not representative of all real-world tool responses. Multi-fixture corpus planned for v3.
2. **TOON roundtrip limitation**: Root-level scalar keys after large mixed-type arrays are not
   recovered by the TOON decoder. Documented in `tests/pipeline_retention.rs`.
3. **RTK output filtering**: Runtime output compression data from one-time SSH collection.
   Not automatically reproducible. Serves as reference only.
4. **Cost projections**: Arithmetic extrapolation from single fixture × linear scaling.
   Not suitable for production cost planning without real workload validation.
5. **Default config only**: All measurements use default compressor settings.
   Production adapters may use different configurations with different results.

## Version note

Reconstructed against tokenless **0.7.1**. The 0.2.0-era reports used
`ResponseCompressor` default `truncate_arrays_at = 16`; it is **32** now, so
the `items/*` and `medium/large/huge` response curves flatten after 32 items
rather than 16. The curve shape matches the report; the truncation knee moved.
