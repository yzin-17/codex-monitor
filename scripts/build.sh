#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-upstream.py
exec ./scripts/build-app.sh
