#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DATE=$(date +%Y-%m-%d)
export LC_ALL=C

echo "=== Running prepare.sh ==="
./prepare.sh

echo ""
echo "=== Building all-update-edges-incident.txt ==="
go run ./ --catalogs-dir catalogs/incident --recent-catalogs-dir catalogs/incident | sort -u > all-update-edges-incident.txt
echo "Wrote all-update-edges-incident.txt"

echo ""
echo "=== Building all-update-edges-latest.txt ==="
go run ./ | sort -u > all-update-edges-latest.txt
echo "Wrote all-update-edges-latest.txt"

echo ""
echo "=== Building bad-csvs-by-ocp-version-incident.json ==="
python3 table-to-json.py < all-update-edges-incident.txt > bad-csvs-by-ocp-version-incident.json
echo "Wrote bad-csvs-by-ocp-version-incident.json"

echo ""
echo "=== Building bad-csvs-by-ocp-version-latest.json ==="
python3 table-to-json.py < all-update-edges-latest.txt > bad-csvs-by-ocp-version-latest.json
echo "Wrote bad-csvs-by-ocp-version-latest.json"

echo ""
echo "=== Building aggregated-option-a-direction-incident.txt ==="
./aggregate-update-edges.sh all-update-edges-incident.txt > aggregated-option-a-direction-incident.txt
echo "Wrote aggregated-option-a-direction-incident.txt"

echo ""
echo "=== Building aggregated-option-a-direction-latest.txt ==="
./aggregate-update-edges.sh all-update-edges-latest.txt > aggregated-option-a-direction-latest.txt
echo "Wrote aggregated-option-a-direction-latest.txt"

echo ""
echo "Done!"
