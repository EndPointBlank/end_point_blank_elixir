#!/usr/bin/env bash
# Run the test suite for end_point_blank (Elixir).
set -euo pipefail
cd "$(dirname "$0")"
exec mix test "$@"
