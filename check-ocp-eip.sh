
#!/usr/bin/env bash

# ============================================================
# OCP EIP UPGRADE VALIDATION
#
# Usage:
#   ./ocp-eip-validation.sh before
#   ./ocp-eip-validation.sh after
#
# Requirements:
#   oc, jq, ssh, getent
#
# SSH:
#   ssh -i ./id_rsa core@node-hostname
# ============================================================

set -uo pipefail

MODE="${1:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"

BASE="$DIR/eip-baseline"
SSH_KEY="$DIR/id_rsa"
APP_HOSTS="$DIR/app-hostnames.txt"

PASS=0
FAIL=0
WARN=0

pass() { echo "[PASS] $*"; ((PASS+=1)); }
fail() { echo "[FAIL] $*"; ((FAIL+=1)); }
warn() { echo "[WARN] $*"; ((WARN+=1)); }
log()  { echo; echo "========== $* =========="; }

# ------------------------------------------------------------
# INITIAL CHECK
# ------------------------------------------------------------

[[ "$MODE" == "before" || "$MODE" == "after" ]] || {
    echo "Usage: $0 {before|after}"
    exit 2
}

for cmd in oc jq ssh getent; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing dependency: $cmd"
        exit 2
    }
done

[[ -f "$SSH_KEY" ]] || {
    echo "Missing SSH key: $SSH_KEY"
    exit 2
}

[[ -f "$APP_HOSTS" ]] || {
    echo "Missing application hostname file: $APP_HOSTS"
    exit 2
}

oc whoami >/dev/null 2>&1 || {
    echo "OCP login failed"
    exit 2
}

mkdir -p "$BASE"

CLUSTER=$(oc get ns kube-system -o jsonpath='{.metadata.uid}')

# ------------------------------------------------------------
# NODE INVENTORY
# ------------------------------------------------------------

collect_nodes() {
    oc get nodes -o json | jq -r '
    .items[] |
    [
      .metadata.name,
      ([.status.addresses[] |
        select(.type=="InternalIP") | .address][0] // "N/A"),
      ([.status.addresses[] |
        select(.type=="Hostname") | .address][0] // .metadata.name),
      ([.status.conditions[] |
        select(.type=="Ready") | .status][0] // "Unknown")
    ] | @tsv' | sort
}

# ------------------------------------------------------------
# NTP CHECK VIA SSH
# ------------------------------------------------------------

collect_ntp() {
    local output="$1"
    : > "$output"

    while IFS=$'\t' read -r node ip hostname ready; do

        result=$(ssh -i "$SSH_KEY" "core@$hostname" \
          "sudo chronyc tracking && sudo chronyc sources -n" \
          2>/dev/null || true)

        if [[ -z "$result" ]]; then
            echo -e "$node\tUNKNOWN\t0\tNONE" >> "$output"
            continue
        fi

        leap=$(echo "$result" |
          sed -n 's/^Leap status[[:space:]]*:[[:space:]]*//p' |
          tail -1 | xargs)

        stratum=$(echo "$result" |
          sed -n 's/^Stratum[[:space:]]*:[[:space:]]*//p' |
          tail -1 | xargs)

        source=$(echo "$result" |
          awk '$1 ~ /^\^\*/ {print $2; exit}')

        echo -e "$node\t${leap:-UNKNOWN}\t${stratum:-0}\t${source:-NONE}" \
          >> "$output"

    done < <(collect_nodes)
}

check_ntp() {
    local file="$1"

    log "NTP Synchronization"

    while IFS=$'\t' read -r node leap stratum source; do

        [[ "$leap" == "Normal" ]] &&
            pass "$node NTP synchronized" ||
            fail "$node NTP unsynchronized ($leap)"

        if [[ "$stratum" =~ ^[0-9]+$ ]] &&
           (( stratum >= 1 && stratum <= 15 )); then
            pass "$node NTP stratum=$stratum"
        else
            fail "$node invalid NTP stratum=$stratum"
        fi

        [[ "$source" != "NONE" ]] &&
            pass "$node NTP source=$source" ||
            fail "$node no selected NTP source"

    done < "$file"
}

# ------------------------------------------------------------
# CLUSTER OPERATORS
# ------------------------------------------------------------

collect_co() {
    oc get co -o json > "$1"
}

check_co() {
    local file="$1"

    log "Cluster Operators"

    while IFS=$'\t' read -r name a p d; do

        if [[ "$a" == "True" &&
              "$p" == "False" &&
              "$d" == "False" ]]; then
            pass "$name"
        else
            fail "$name Available=$a Progressing=$p Degraded=$d"
        fi

    done < <(jq -r '
      .items[] |
      [
        .metadata.name,
        ([.status.conditions[] |
          select(.type=="Available") | .status][0] // "Unknown"),
        ([.status.conditions[] |
          select(.type=="Progressing") | .status][0] // "Unknown"),
        ([.status.conditions[] |
          select(.type=="Degraded") | .status][0] // "Unknown")
      ] | @tsv' "$file")
}

# ------------------------------------------------------------
# NODE CHECK
# ------------------------------------------------------------

check_nodes() {
    log "Node Status"

    while IFS=$'\t' read -r name ip hostname ready; do

        [[ "$ready" == "True" ]] &&
            pass "$name Ready" ||
            fail "$name NotReady"

        [[ "$ip" != "N/A" ]] &&
            pass "$name InternalIP=$ip" ||
            fail "$name InternalIP missing"

    done < <(collect_nodes)
}

compare_nodes() {
    log "Node IP / Hostname Comparison"

    while IFS=$'\t' read -r name ip hostname ready; do

        current=$(awk -F'\t' -v n="$name" \
          '$1==n {print $2 "\t" $3}' "$BASE/nodes-after.tsv")

        if [[ -z "$current" ]]; then
            fail "Node missing: $name"
            continue
        fi

        IFS=$'\t' read -r new_ip new_hostname <<< "$current"

        [[ "$ip" == "$new_ip" ]] &&
            pass "$name IP unchanged: $ip" ||
            fail "$name IP changed: $ip -> $new_ip"

        [[ "$hostname" == "$new_hostname" ]] &&
            pass "$name hostname unchanged" ||
            fail "$name hostname changed"

    done < "$BASE/nodes-before.tsv"

    while IFS=$'\t' read -r name ip hostname ready; do
        if ! awk -F'\t' -v n="$name" \
            '$1==n {found=1} END {exit !found}' "$BASE/nodes-before.tsv"; then
            fail "Unexpected new node: $name"
        fi
    done < "$BASE/nodes-after.tsv"
}

# ------------------------------------------------------------
# POD CHECK
# ------------------------------------------------------------

collect_pods() {
    oc get pods -A -o json > "$1"
}

check_pods() {
    local file="$1"

    log "Pod Health - All Namespaces"

    while IFS=$'\t' read -r ns name phase ready total; do

        if [[ "$phase" == "Succeeded" ]]; then
            pass "$ns/$name completed"
        elif [[ "$phase" == "Running" &&
                "$total" -gt 0 &&
                "$ready" -eq "$total" ]]; then
            pass "$ns/$name healthy ($ready/$total)"
        else
            fail "$ns/$name unhealthy ($phase $ready/$total)"
        fi

    done < <(jq -r '
      .items[] |
      [
        .metadata.namespace,
        .metadata.name,
        .status.phase // "Unknown",
        ([.status.containerStatuses[]? |
          select(.ready==true)] | length),
        ([.status.containerStatuses[]?] | length)
      ] | @tsv' "$file")
}

compare_pods() {
    log "Pod Restart Comparison"

    while IFS=$'\t' read -r ns name uid old_restart; do

        current=$(jq -r --arg ns "$ns" \
          --arg name "$name" --arg uid "$uid" '
          [.items[] |
           select(
             .metadata.namespace==$ns and
             .metadata.name==$name and
             .metadata.uid==$uid
           ) |
           ([.status.containerStatuses[]? |
             .restartCount] | add // 0)] | .[0] // empty
        ' "$BASE/pods-after.json")

        if [[ -z "$current" ]]; then
            continue
        elif (( current > old_restart )); then
            warn "$ns/$name restart increased: $old_restart -> $current"
        else
            pass "$ns/$name restart unchanged"
        fi

    done < <(jq -r '
      .items[] |
      [
        .metadata.namespace,
        .metadata.name,
        .metadata.uid,
        ([.status.containerStatuses[]? |
          .restartCount] | add // 0)
      ] | @tsv' "$BASE/pods-before.json")
}

# ------------------------------------------------------------
# DNS CHECK FROM BASTION
# ------------------------------------------------------------

resolve_dns() {
    getent ahostsv4 "$1" 2>/dev/null |
      awk '{print $1}' | sort -u | paste -sd ',' -
}

collect_dns() {
    local output="$1"
    : > "$output"

    while IFS= read -r hostname; do
        [[ -z "$hostname" || "$hostname" =~ ^# ]] && continue

        echo -e "$hostname\t$(resolve_dns "$hostname")" >> "$output"

    done < "$APP_HOSTS"

    while IFS=$'\t' read -r node ip hostname ready; do
        echo -e "$hostname\t$(resolve_dns "$hostname")" >> "$output"
    done < <(collect_nodes)

    sort -u "$output" -o "$output"
}

check_dns() {
    local file="$1"

    log "DNS Resolution - Bastion"

    while IFS=$'\t' read -r hostname result; do

        [[ -n "$result" ]] &&
            pass "$hostname -> $result" ||
            fail "$hostname DNS resolution failed"

    done < "$file"
}

compare_dns() {
    log "DNS Comparison"

    while IFS=$'\t' read -r hostname old; do

        current=$(awk -F'\t' -v h="$hostname" \
          '$1==h {print $2}' "$BASE/dns-after.tsv")

        if [[ -z "$current" ]]; then
            fail "$hostname missing after upgrade"
        elif [[ -z "$old" ]]; then
            warn "$hostname had no valid BEFORE resolution"
        elif [[ "$old" == "$current" ]]; then
            pass "$hostname unchanged: $current"
        else
            fail "$hostname DNS changed: $old -> $current"
        fi

    done < "$BASE/dns-before.tsv"
}

# ------------------------------------------------------------
# OPENSHIFT INTERNAL DNS COMPONENTS
# ------------------------------------------------------------

check_internal_dns() {
    log "OpenShift Internal DNS"

    if oc get co dns >/dev/null 2>&1; then
        pass "DNS Cluster Operator exists"
    else
        fail "DNS Cluster Operator unavailable"
    fi

    bad=$(oc get pods -n openshift-dns -o json |
      jq '[.items[] |
        select(.metadata.name | startswith("dns-default")) |
        select(
          .status.phase != "Running" or
          ([.status.containerStatuses[]? |
            select(.ready==true)] | length) !=
          ([.status.containerStatuses[]?] | length)
        )] | length')

    if (( bad == 0 )); then
        pass "DNS pods healthy"
    else
        fail "DNS unhealthy pods: $bad"
    fi

    endpoints=$(oc get endpoints dns-default \
      -n openshift-dns -o json |
      jq '[.subsets[]?.addresses[]?] | length')

    if (( endpoints > 0 )); then
        pass "DNS endpoints available: $endpoints"
    else
        fail "DNS endpoints unavailable"
    fi
}

# ------------------------------------------------------------
# REPORT
# ------------------------------------------------------------

report() {
    echo
    echo "================================================"
    echo "          OCP EIP VALIDATION REPORT"
    echo "================================================"
    echo "Mode    : ${MODE^^}"
    echo "Cluster : $CLUSTER"
    echo "Time    : $(date)"
    echo "PASS    : $PASS"
    echo "FAIL    : $FAIL"
    echo "WARN    : $WARN"
    echo "================================================"

    if (( FAIL > 0 )); then
        echo "RESULT: FAILED"
        exit 1
    fi

    echo "RESULT: PASSED"
    exit 0
}

# ------------------------------------------------------------
# BEFORE
# ------------------------------------------------------------

if [[ "$MODE" == "before" ]]; then

    log "BEFORE EIP UPGRADE"

    echo "$CLUSTER" > "$BASE/cluster-id"

    collect_co "$BASE/co-before.json"
    collect_pods "$BASE/pods-before.json"
    collect_nodes > "$BASE/nodes-before.tsv"

    collect_ntp "$BASE/ntp-before.tsv"
    collect_dns "$BASE/dns-before.tsv"

    check_co "$BASE/co-before.json"
    check_nodes
    check_pods "$BASE/pods-before.json"
    check_ntp "$BASE/ntp-before.tsv"
    check_dns "$BASE/dns-before.tsv"
    check_internal_dns

    log "Baseline saved: $BASE"

# ------------------------------------------------------------
# AFTER
# ------------------------------------------------------------

else

    log "AFTER EIP UPGRADE"

    [[ -s "$BASE/cluster-id" ]] ||
        { echo "Baseline not found"; exit 2; }

    [[ "$(cat "$BASE/cluster-id")" == "$CLUSTER" ]] ||
        { echo "Wrong cluster baseline"; exit 2; }

    for file in co-before.json pods-before.json \
                nodes-before.tsv ntp-before.tsv dns-before.tsv; do
        [[ -s "$BASE/$file" ]] ||
            { echo "Missing baseline: $file"; exit 2; }
    done

    collect_co "$BASE/co-after.json"
    collect_pods "$BASE/pods-after.json"
    collect_nodes > "$BASE/nodes-after.tsv"

    collect_ntp "$BASE/ntp-after.tsv"
    collect_dns "$BASE/dns-after.tsv"

    check_co "$BASE/co-after.json"
    check_nodes
    check_pods "$BASE/pods-after.json"

    compare_nodes

    compare_pods

    check_ntp "$BASE/ntp-after.tsv"

    check_dns "$BASE/dns-after.tsv"
    compare_dns

    check_internal_dns

fi

report
