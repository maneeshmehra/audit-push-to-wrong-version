#!/bin/sh
#
# list operators who are not yet resolved, given two mechanisms for resolution:
# * Satisfying this repo's catalog/channel membership checks, or
# * Getting a line in the umbrella KCS that explains why a catalog/channel update is not required.

echo 'Resolved via catalog updates:'
comm -23 <(jq -r 'to_entries[].value[]' archive/original/bad-csvs-by-ocp-version.json | cut -d. -f1 | sort -u) <(cut -d' ' -f3 all-update-edges-latest.txt | cut -d. -f1 | sort -u)

echo
echo 'Resolved via KCS text (resolution.txt, scraped from https://access.redhat.com/solutions/7137887 ):'
wc -l resolution.txt

echo
echo 'Still unresolved:'
comm -23 <(cut -d' ' -f1 all-update-edges-latest.txt | sort | uniq) <(cut -d'	' -f1 resolution.txt | sort)
