#!/bin/bash
# Convert ImageDigestMirrorSet YAML to registries.conf TOML format
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <idms.yaml>" >&2
    exit 1
fi

idms_file="$1"

if [ ! -f "$idms_file" ]; then
    echo "Error: File not found: $idms_file" >&2
    exit 1
fi

# Verify it's an IDMS resource
kind=$(yq eval '.kind' "$idms_file")
if [ "$kind" != "ImageDigestMirrorSet" ]; then
    echo "Error: Not an ImageDigestMirrorSet (found: $kind)" >&2
    exit 1
fi

# Get number of mirror entries
count=$(yq eval '.spec.imageDigestMirrors | length' "$idms_file")

# Generate TOML for each mirror entry
for ((i=0; i<count; i++)); do
    source=$(yq eval ".spec.imageDigestMirrors[$i].source" "$idms_file")
    mirrors=$(yq eval ".spec.imageDigestMirrors[$i].mirrors[]" "$idms_file")

    echo "[[registry]]"
    echo "  prefix = \"$source\""
    echo "  location = \"$source\""
    echo ""

    while IFS= read -r mirror; do
        [ -z "$mirror" ] && continue
        echo "  [[registry.mirror]]"
        echo "    location = \"$mirror\""
    done <<< "$mirrors"

    echo ""
done
