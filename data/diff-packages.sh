#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
A="$DIR/packages-catalog.txt"
B="$DIR/packages-telemetry.txt"

echo "=== In catalog only ==="
comm -23 <(sort "$A") <(sort "$B")

echo ""
echo "=== In telemetry only ==="
comm -13 <(sort "$A") <(sort "$B")

echo ""
echo "=== Intersection ==="
comm -12 <(sort "$A") <(sort "$B")
