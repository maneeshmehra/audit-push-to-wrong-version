#!/bin/bash
# Aggregates all-update-edges data into summary lines showing what patches
# each package needs to publish, in which channels, for each OCP version.
#
# Usage: ./aggregate-update-edges.sh <all-update-edges-file>
#
# Input format (space-delimited):
#   <packageName> <ocpVersion> <csv> <channels> <otherChannels> <bool>
#
# Output format:
#   <packageName> needs to publish patches for <minorVersions> in <channels> in <ocpVersions>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <all-update-edges-file>" >&2
    exit 1
fi

awk '
# Version sort: split on ", ", compare major.minor numerically, rejoin
function vsort(str,    arr, n, i, j, tmp, ai, aj, avi, avj) {
    n = split(str, arr, ", ")
    for (i = 2; i <= n; i++) {
        tmp = arr[i]
        split(tmp, avi, ".")
        j = i - 1
        while (j >= 1) {
            split(arr[j], avj, ".")
            if ((avj[1]+0 > avi[1]+0) || (avj[1]+0 == avi[1]+0 && avj[2]+0 > avi[2]+0))
                arr[j+1] = arr[j]
            else
                break
            j--
        }
        arr[j+1] = tmp
    }
    str = arr[1]
    for (i = 2; i <= n; i++) str = str ", " arr[i]
    return str
}
{
    pkg = $1
    ocp = $2
    csv = $3

    # Extract major.minor from the version embedded in the CSV name.
    # Handles both "name.vMAJOR.MINOR..." and "name.MAJOR.MINOR..." forms,
    # even when the CSV name differs from the package name.
    if (match(csv, /\.v[0-9]/)) {
        ver = substr(csv, RSTART + 2)
    } else if (match(csv, /\.[0-9]/)) {
        ver = substr(csv, RSTART + 1)
    } else {
        ver = csv
    }
    split(ver, vparts, ".")
    minor = vparts[1] "." vparts[2]

    # Channel(s) from column 4, strip quotes, split on comma
    chan = $4
    gsub(/"/, "", chan)

    key = pkg "\t" ocp

    # Track unique minor versions per (package, ocpVersion)
    if (!seen_minor[key, minor]++) {
        minors[key] = minors[key] ? minors[key] ", " minor : minor
    }

    # Split comma-separated channels and track unique ones
    n = split(chan, chanlist, ",")
    for (c = 1; c <= n; c++) {
        ch = chanlist[c]
        if (ch != "" && !seen_chan[key, ch]++) {
            chans[key] = chans[key] ? chans[key] ", " ch : ch
        }
    }

    # Preserve input order of keys
    if (!seen_key[key]++) {
        keys[++nkeys] = key
    }
}
END {
    # Second pass: merge lines with identical (pkg, minors, channels)
    for (i = 1; i <= nkeys; i++) {
        key = keys[i]
        split(key, p, "\t")
        pkg = p[1]
        agg = pkg "\t" minors[key] "\t" chans[key]

        if (!seen_agg[agg]++) {
            agg_keys[++nagg] = agg
        }
        ocps[agg] = ocps[agg] ? ocps[agg] ", " p[2] : p[2]
    }

    for (i = 1; i <= nagg; i++) {
        agg = agg_keys[i]
        split(agg, a, "\t")
        printf "In OCP version catalogs %s, package %s needs to publish patches for operator minor versions %s in all of the following channels: %s\n", vsort(ocps[agg]), a[1], vsort(a[2]), a[3]
    }
}
' "$1"
