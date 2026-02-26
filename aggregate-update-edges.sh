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
# Alphabetical sort for comma-separated strings (e.g. channel names)
function asort_csv(str,    arr, n, i, j, tmp) {
    n = split(str, arr, ", ")
    for (i = 2; i <= n; i++) {
        tmp = arr[i]
        j = i - 1
        while (j >= 1 && arr[j] > tmp) {
            arr[j+1] = arr[j]
            j--
        }
        arr[j+1] = tmp
    }
    str = arr[1]
    for (i = 2; i <= n; i++) str = str ", " arr[i]
    return str
}
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

    # Split comma-separated channels and track unique ones per minor version
    n = split(chan, chanlist, ",")
    for (c = 1; c <= n; c++) {
        ch = chanlist[c]
        if (ch != "" && !seen_chan[key, minor, ch]++) {
            minor_chans[key, minor] = minor_chans[key, minor] ? minor_chans[key, minor] ", " ch : ch
        }
    }

    # Preserve input order of keys
    if (!seen_key[key]++) {
        keys[++nkeys] = key
    }
}
END {
    # Second pass: build per-minor-version channel descriptions and merge identical ones
    for (i = 1; i <= nkeys; i++) {
        key = keys[i]
        split(key, p, "\t")
        pkg = p[1]

        # Sort minors and group by channel set
        sorted_minors = vsort(minors[key])
        nm = split(sorted_minors, marr, ", ")

        # Group minors sharing the same channel set, preserving sorted order
        ngrp = 0
        delete grp_chans
        delete grp_minors
        delete seen_grp
        for (j = 1; j <= nm; j++) {
            m = marr[j]
            ch = asort_csv(minor_chans[key, m])
            if (!(ch in seen_grp)) {
                seen_grp[ch] = ++ngrp
                grp_chans[ngrp] = ch
            }
            g = seen_grp[ch]
            grp_minors[g] = grp_minors[g] ? grp_minors[g] ", " m : m
        }

        # Build description from groups
        desc = ""
        for (j = 1; j <= ngrp; j++) {
            if (desc) desc = desc ", "
            desc = desc grp_minors[j] " (in " grp_chans[j] ")"
        }

        # Merge identical descriptions across OCP versions within the same package
        agg = pkg "\t" desc
        if (!seen_agg[agg]++) {
            pkg_agg_keys[pkg, ++pkg_nagg[pkg]] = agg
        }
        ocps[agg] = ocps[agg] ? ocps[agg] ", " p[2] : p[2]

        if (!seen_pkg[pkg]++) {
            pkgs[++npkgs] = pkg
        }
    }

    for (i = 1; i <= npkgs; i++) {
        pkg = pkgs[i]
        printf "%s\n", pkg
        for (j = 1; j <= pkg_nagg[pkg]; j++) {
            agg = pkg_agg_keys[pkg, j]
            split(agg, a, "\t")
            printf "  - %s: publish patches for operator minor versions %s\n", vsort(ocps[agg]), a[2]
        }
        printf "\n"
    }
}
' "$1"
