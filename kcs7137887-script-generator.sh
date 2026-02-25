#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


ORIGINAL_FILE="${1:-bad-csvs-by-ocp-version.json}"
CURRENT_FILE="${2:-all-update-edges-2026-02-24.txt}"

# I am not sure if there is an API for listing rolling-stream operator names, but this join seems close:
#
#   $ join <(jq -r 'to_entries[].value[]' bad-csvs-by-ocp-version.json | sed 's/[.].*//' | sort | uniq) <(curl -s https://access.redhat.com/support/policy/updates/openshift_operators | grep -o 'id="[^"]*-Rolling"\|.*href="[^"]*?operator=[^"]*' | grep -A1 -- -Rolling | sed -n 's/.*operator=//p' | sort | uniq)

ROLLING_STREAM_OPERATORS="network-observability-operator
"

cat <<EOF
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Change-log:
# * 2026-02-13 v1 (sha256 5d2da3dad20aa839a6c261c78af5b09d89364190b55da67a8ebdf75d26db33aa)
# * 2026-02-25 v2 (sha256 in KCS; drop this line and hash to get da10a117da87e2e6106ab9f933bb938763ec3035efc5b49bcacfe66290ec284b)
#   * aws-efs-csi-driver-operator.v4.18.0-202602040643 added to 4.14 concerns (v1 had accidentally dropped it for testing)
#   * some rolling-stream operators (but not yet all) have committed to supporting identical catalogs on all supported OCP releases, https://access.redhat.com/support/policy/updates/openshift_operators#rolling-stream
#   * some operators (e.g. openshift-builds-operator) have already shipped sufficient versions into older catalogs to make the incident-induced skew a non-issue for those operators.
#   * use operators.operators.coreos.com instead of direct clusterserviceversions.operators.coreos.com for lookup, so we don't have to iterate over namespaces.

CLUSTER_VERSION="\$(oc get --output jsonpath='{.status.desired.version}' clusterversion version)"
MAJOR_MINOR="\${CLUSTER_VERSION%[.][^.]*}"

case "\${MAJOR_MINOR}" in
EOF

jq -r 'to_entries[] | "  " + .key + ")\n    ORIGINALLY_CONCERNING=\"" + (.value | sort | join("\n")) + "\n\"\n    ;;"' "${ORIGINAL_FILE}"

cat <<EOF
  *)
    printf 'unrecognized major-minor version %s (parsed from %s).  Are you 4.12 through 4.17?\n' "\${MAJOR_MINOR}" "\${CLUSTER_VERSION}" >&2
    exit 1
esac

case "\${MAJOR_MINOR}" in
EOF

./table-to-json.py < "${CURRENT_FILE}" | jq -r 'to_entries[] | "  " + .key + ")\n    CURRENTLY_CONCERNING=\"" + (.value | sort | join("\n")) + "\n\"\n    ;;"'

cat <<EOF
  *)
    printf 'unrecognized major-minor version %s (parsed from %s).  Are you 4.12 through 4.17?\n' "\${MAJOR_MINOR}" "\${CLUSTER_VERSION}" >&2
    exit 1
esac

WARNINGS="\$(oc get -o jsonpath='{range .items[*].status.components.refs[?(.kind == "ClusterServiceVersion")]}{.name}{"\n"}{end}' operators.operators.coreos.com | sort | uniq | join - <(printf '%s' "\${ORIGINALLY_CONCERNING}" | sort))"

NO_LONGER_CONCERNING="\$(printf '%s' "\${WARNINGS}" | sort | comm -2 -3 - <(printf '%s' "\${CURRENTLY_CONCERNING}" | sort))"
if test -n "\${NO_LONGER_CONCERNING}"
then
  printf 'The v1 script was concerned about these operators, but they have since been added to %s catalogs, although you might need to change the channel:\n%s\n\n' "\${MAJOR_MINOR}" "\${NO_LONGER_CONCERNING}"
  WARNINGS="\$(printf '%s' "\${WARNINGS}" | sort | join - <(printf '%s' "\${CURRENTLY_CONCERNING}" | sort))"
fi

ROLLING_STREAM_REGEXP='$(printf "^\(%s\)[.]" "${ROLLING_STREAM_OPERATORS}" | sed -z 's/\n/\\\|/g')'
ROLLING_STREAM="\$(printf '%s' "\${WARNINGS}" | (grep "\${ROLLING_STREAM_REGEXP}" || true))"
if test -n "\${ROLLING_STREAM}"
then
  printf 'The v1 script was concerned about these rolling-stream operators, but they will be included in future %s catalogs:\n%s\n\n' "\${MAJOR_MINOR}" "\${ROLLING_STREAM}"
  WARNINGS="\$(printf '%s' "\${WARNINGS}" | (grep -v "\${ROLLING_STREAM_REGEXP}" || true))"
fi

if test -z "\${WARNINGS}"
then
  printf 'No concerning 4.18 ClusterServiceVersions detected.\n'
  exit 0
fi

printf 'Concerning 4.18 ClusterServiceVersions detected:\n%s\n' "\${WARNINGS}"
exit 1
EOF
