#!/usr/bin/env bash
# Copyright 2026 Alibaba Cloud
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# One-shot runner for the tokenless benchmark suite.
#
#   ./run-benchmarks.sh            # build, tests, benches, compression report
#   ./run-benchmarks.sh --quick    # skip criterion benches (tests + report only)
#
# The criterion benches follow the report methodology: run this 3 times and
# average the per-benchmark medians (criterion itself uses 100 samples/bench).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

# Record source identity for traceability (git rev + dirty flag).
IDENTITY_FILE="$SCRIPT_DIR/benchmark_identity.json"
GIT_REV=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY=$(git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null && echo "false" || echo "true")
cat > "$IDENTITY_FILE" <<EOF
{
  "git_rev": "$GIT_REV",
  "dirty": $GIT_DIRTY,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname -s 2>/dev/null || echo unknown)"
}
EOF
echo "==> Source identity recorded: $IDENTITY_FILE"

echo "==> Building benchmark suite (release)"
cargo build --release

echo "==> Quality + adversarial tests (cargo test)"
cargo test --release

if [[ "$QUICK" -eq 0 ]]; then
    LOG_FILE="benchmark_output_$(date +%Y%m%d_%H%M%S).log"
    echo "==> Performance benchmarks (criterion, 100 samples each)"
    cargo bench 2>&1 | tee "$LOG_FILE"
    echo "==> Benchmark output saved to $LOG_FILE"
fi

echo "==> Compression-rate report (Rust in-process)"
cargo run --release --bin compression_rate

echo "==> Done. Criterion HTML reports under target/criterion/."