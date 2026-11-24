#!/usr/bin/env bash
# Word error of the local speech model on public FLEURS test clips, as a wiring check.
set -euo pipefail
cd "$(dirname "$0")/.."

count=20
base=https://huggingface.co/datasets/google/fleurs/resolve/main/data
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift build --product narrari-dev -c release
for language in en_us bg_bg; do
  mkdir -p "$work/$language"
  curl -fsSL "$base/$language/test.tsv" -o "$work/$language.tsv"
  # Stops reading after $count clips, so curl ends with a broken pipe by design.
  curl -fsSL "$base/$language/audio/test.tar.gz" 2>/dev/null \
    | python3 -I scripts/take-clips.py "$work/$language" "$work/$language.tsv" "$count" || true
  echo "$language"
  .build/release/narrari-dev accuracy "$work/$language"
done
