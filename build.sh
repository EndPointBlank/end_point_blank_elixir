#!/usr/bin/env bash
# Fetch dependencies and compile so the test suite can run.
set -euo pipefail
cd "$(dirname "$0")"
mix deps.get
exec mix compile
