#!/bin/sh
# Real-file checks for the .sof reader/writer (Sources/Quartzite/SOF.swift).
# Samples are not in git; see docs/SOF_FORMAT.md ("Samples") for where they came from.
#   ci/sof_check.sh [samples-dir]     (default: ../sof-samples next to the repo)
set -e
cd "$(dirname "$0")/.."
DIR="${1:-../sof-samples}"
if [ ! -d "$DIR" ]; then echo "sample folder $DIR not found; skipping"; exit 0; fi
swift build -c release >/dev/null
.build/release/Quartzite --sof-verify "$DIR"
