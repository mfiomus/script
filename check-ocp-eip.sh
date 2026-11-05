
#!/usr/bin/env bash

echo "======================================"
echo " OCP BEFORE / AFTER EIP VALIDATION"
echo "======================================"
echo "Date: $(date)"
echo

echo "========== 1. CLUSTER OPERATORS =========="
oc get co
echo

echo "========== 2. NODES =========="
oc get nodes -o wide
echo

echo "========== 3. PODS ALL NAMESPACES =========="
oc get pods -A
echo

echo "========== 4. DNS RESOLUTION =========="

# Hostnames to check
HOST_FILE="app-hostnames.txt"

if [[ -f "$HOST_FILE" ]]; then
    while IFS= read -r hostname; do
        [[ -z "$hostname" || "$hostname" =~ ^# ]] && continue

        echo
        echo "Hostname: $hostname"
        echo "Forward DNS:"
        dig +short "$hostname"
    done < "$HOST_FILE"
else
    echo "WARNING: $HOST_FILE not found. Skipping application DNS check."
fi

echo
echo "========== NODE DNS / REVERSE DNS =========="

oc get nodes -o json |
jq -r '.items[] | [.metadata.name, ([.status.addresses[] | select(.type=="InternalIP") | .address][0])] | @tsv' |
while IFS=$'\t' read -r hostname ip; do
    echo
    echo "Node: $hostname"
    echo "Internal IP: $ip"

    echo "Forward DNS:"
    dig +short "$hostname"

    echo "Reverse DNS:"
    dig +short -x "$ip"
done

echo
echo "========== 5. NTP CHECK =========="

oc get nodes -o json |
jq -r '.items[].metadata.name' |
while read -r node; do
    echo
    echo "Node: $node"

    ssh -i id_rsa "core@$node" \
        "sudo -n chronyc tracking && sudo -n chronyc sources -n"
done

echo
echo "======================================"
echo " VALIDATION COMPLETED"
echo "======================================"
