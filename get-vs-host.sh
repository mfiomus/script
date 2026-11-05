
#!/usr/bin/env bash
set -euo pipefail

OUTPUT="${1:-app-hostnames.txt}"

# Check dependencies
for cmd in oc jq sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

# Check OpenShift login
if ! oc whoami >/dev/null 2>&1; then
    echo "ERROR: Not logged in to OpenShift."
    exit 1
fi

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

echo "Extracting FQDNs from VirtualServices..."

# Extract only the second entry from spec.hosts
oc get virtualservices.networking.istio.io -A -o json |
jq -r '
    .items[]
    | (.spec.hosts // [])
    | .[1] // empty
    | select(type == "string" and length > 0)
' |
sort -u > "$TMP_FILE"

if [[ ! -s "$TMP_FILE" ]]; then
    echo "ERROR: No second host entries found in VirtualServices."
    exit 1
fi

mv "$TMP_FILE" "$OUTPUT"

COUNT=$(wc -l < "$OUTPUT" | tr -d ' ')

echo "=================================="
echo "VirtualService FQDN extraction"
echo "=================================="
echo "Total unique FQDNs : $COUNT"
echo "Output file        : $OUTPUT"
echo "=================================="
echo "Done."
