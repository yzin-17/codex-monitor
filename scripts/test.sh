#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/run-regression-tests.sh
