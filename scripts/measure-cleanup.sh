#!/usr/bin/env bash
# Time and fact-keeping of each clean-up model the app offers on the sample dictations, then clean-up time by dictation
# length, then whether replies after an unload and reload match the first load's.
# Reply tokens and decode speed: /usr/bin/log show --last 10m --predicate 'process == "narrari-dev"'
set -euo pipefail
cd "$(dirname "$0")/.."

outputs=${1:-${TMPDIR:-/tmp}/narrari-cleanup-outputs.md}

swift build --product narrari-dev -c release
.build/release/narrari-dev cleanup scripts/fixtures/cleanup-samples.json "$outputs"
.build/release/narrari-dev cleanup-speed scripts/fixtures/cleanup-lengths.json
.build/release/narrari-dev cleanup-reload 10 scripts/fixtures/cleanup-lengths.json scripts/fixtures/cleanup-fillers.json \
  | grep -E '^summary|unlike-dictation'
