#!/usr/bin/env bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the script directory to ensure all operations happen there
cd "$SCRIPT_DIR"
echo "Working in directory: $SCRIPT_DIR"


# Check required tools
for tool in curl opm skopeo sha256sum; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool is not installed or not in PATH"
        exit 1
    fi
done

IMAGES=(registry.redhat.io/redhat/redhat-operator-index)
INCIDENT_IMAGE_4_18="registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:210fa4ca556f36688bcab0bf949b698618f44380dc8f1e8a214ee62474664b7d"  # Requires RH VPN access
INCIDENT_VERSIONS=(v4.17-1770172614 v4.16-1770168058 v4.15-1770167994 v4.14-1770255575 v4.13-1770313132 v4.12-1770182999)
LATEST_VERSIONS=(v4.17 v4.16 v4.15 v4.14 v4.13 v4.12)

get_image_digest() {
    local image_ref=$1
    skopeo inspect --raw docker://$image_ref | sha256sum | cut -d' ' -f1
}

is_catalog_current() {
    local catalog_dir="$1"
    local current_digest="$2"
    
    if [[ ! -f "$catalog_dir/.metadata/digest" ]]; then
        return 1  # No digest file, needs update
    fi
    
    local stored_digest
    stored_digest=$(cat "$catalog_dir/.metadata/digest" 2>/dev/null)
    
    if [[ "$stored_digest" == "$current_digest" ]]; then
        return 0  # Up to date
    else
        return 1  # Needs update
    fi    
}

create_digest() {
    local catalog_dir="$1"
    local digest="$2"
    local image_ref="$3"
    
    mkdir -p $catalog_dir/.metadata
    echo -n $digest > $catalog_dir/.metadata/digest
}

create_indexignore() {
    local catalog_dir="$1"

    cat > "$catalog_dir/.indexignore" << EOF
# This file is used by the File-Based Catalog (FBC) format
# to allow non-FBC files to be included in an FBC directory
.metadata/
EOF
}

pull_catalog() {
    local image_ref="$1"
    local output_dir="$2"

    echo "Ensuring $image_ref exists in $output_dir"

    local current_digest
    current_digest=$(get_image_digest "$image_ref")

    mkdir -p "$output_dir"
    create_indexignore "$output_dir"

    if is_catalog_current "$output_dir" "$current_digest"; then
        echo "$image_ref is up to date (digest: $current_digest)"
        return 0
    fi

    if ! opm render "$image_ref" > "$output_dir/catalog.json"; then
        echo "Failed to download $image_ref"
        exit 1
    fi

    create_digest "$output_dir" "$current_digest" "$image_ref"
    echo "Successfully cached $image_ref (digest: $current_digest)"
}

# If catalogs/latest directory already exists, move it to catalogs/{yyyymmdd_hhmm} based on its modtime
if [[ -d catalogs/latest ]]; then
    mod_date=$(date -r catalogs/latest +%Y%m%d_%H%M)
    backup_dir="catalogs/${mod_date}"
    if [[ -e "$backup_dir" ]]; then
        echo "Error: backup directory $backup_dir already exists"
        exit 1
    fi
    echo "Moving existing catalogs/latest directory to $backup_dir"
    mv catalogs/latest "$backup_dir"
fi

pull_catalog "$INCIDENT_IMAGE_4_18" "catalogs/incident/4.18"

for image in "${IMAGES[@]}"; do
    for version in "${INCIDENT_VERSIONS[@]}"; do
        ocp_version=$(echo "$version" | sed 's/^v//;s/-.*//')
        pull_catalog "$image:$version" "catalogs/incident/$ocp_version"
    done
    for version in "${LATEST_VERSIONS[@]}"; do
        ocp_version=$(echo "$version" | sed 's/^v//')
        pull_catalog "$image:$version" "catalogs/latest/$ocp_version"
    done
done

echo "All downloads completed successfully!"
