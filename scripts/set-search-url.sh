#!/usr/bin/env bash
# Point the manifests' SearchService2/AutoCompleteService2 ids at a different search host.
# Usage: scripts/set-search-url.sh https://bedford-search.onrender.com
set -euo pipefail

base="${1:-}"
if [[ ! "$base" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
    echo "usage: $0 <scheme://host[:port]>   (no path or trailing slash)" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
for f in iiif/*.json; do
    grep -q '/annosearch/' "$f" || continue
    sed -i -E "s#\"https?://[^\"]+/annosearch/#\"$base/annosearch/#g" "$f"
    jq -e . "$f" >/dev/null
    echo "updated $f"
done
