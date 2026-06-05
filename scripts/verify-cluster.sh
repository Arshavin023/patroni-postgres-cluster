#!/usr/bin/env bash
# =============================================================================
# verify-cluster.sh — End-to-end health check for the Patroni PostgreSQL cluster
#
# Run this after deployment to confirm everything is wired up correctly.
# Run it again after any failover test or maintenance window.
#
# Usage:
#   ./scripts/verify-cluster.sh
#
# Prerequisites:
#   - patronictl, psql, etcdctl, and curl must be on PATH
#   - Run from any PostgreSQL node, or a bastion with VPC access
#   - Set the environment variables below before running
# =============================================================================

set -euo pipefail

# ── Configuration — edit these before running ────────────────────────────────
PATRONI_CFG="/etc/patroni/patroni.yml"
ETCD_ENDPOINTS="http://PLACEHOLDER_ETCD_NODE_1_IP:2379,http://PLACEHOLDER_ETCD_NODE_2_IP:2379,http://PLACEHOLDER_ETCD_NODE_3_IP:2379"
NLB_DNS="PLACEHOLDER_NLB_DNS_NAME"
PG_NODE_1="PLACEHOLDER_PG_NODE_1_IP"
PG_NODE_2="PLACEHOLDER_PG_NODE_2_IP"
PG_NODE_3="PLACEHOLDER_PG_NODE_3_IP"
PG_USER="postgres"
STANZA="PLACEHOLDER_STANZA_NAME"
# ─────────────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0

print_header() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════════════════════════"
}

check() {
    local description="$1"
    local result="$2"
    local expected="$3"

    if echo "$result" | grep -q "$expected"; then
        echo "  ✅  $description"
        ((PASS++))
    else
        echo "  ❌  $description"
        echo "      Expected: $expected"
        echo "      Got:      $result"
        ((FAIL++))
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
print_header "1. ETCD Cluster Health"
# ─────────────────────────────────────────────────────────────────────────────

echo "  Running: etcdctl endpoint health"
etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint health --write-out=table 2>&1 || true

echo ""
echo "  Running: etcdctl endpoint status"
etcdctl_status=$(etcdctl --endpoints="$ETCD_ENDPOINTS" endpoint status --write-out=table 2>&1)
echo "$etcdctl_status"
check "ETCD has a leader" "$etcdctl_status" "true"

member_count=$(etcdctl --endpoints="$ETCD_ENDPOINTS" member list 2>&1 | wc -l)
check "ETCD has 3 members" "$member_count" "3"

# ─────────────────────────────────────────────────────────────────────────────
print_header "2. Patroni Cluster Status"
# ─────────────────────────────────────────────────────────────────────────────

patroni_list=$(patronictl -c "$PATRONI_CFG" list 2>&1)
echo "$patroni_list"

check "Patroni cluster has a Leader" "$patroni_list" "Leader"
check "Patroni cluster has at least one Replica" "$patroni_list" "Replica"

# ─────────────────────────────────────────────────────────────────────────────
print_header "3. Patroni REST API Health Endpoints"
# ─────────────────────────────────────────────────────────────────────────────

for node_ip in "$PG_NODE_1" "$PG_NODE_2" "$PG_NODE_3"; do
    primary_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${node_ip}:8008/primary")
    replica_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${node_ip}:8008/replica")
    echo "  Node $node_ip: /primary=$primary_code  /replica=$replica_code"
done

# Exactly one node should return 200 for /primary
primary_count=0
for node_ip in "$PG_NODE_1" "$PG_NODE_2" "$PG_NODE_3"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://${node_ip}:8008/primary")
    [[ "$code" == "200" ]] && ((primary_count++))
done
check "Exactly 1 node is primary" "$primary_count" "1"

# ─────────────────────────────────────────────────────────────────────────────
print_header "4. HAProxy Routing via NLB"
# ─────────────────────────────────────────────────────────────────────────────

write_recovery=$(PGPASSWORD="" psql -h "$NLB_DNS" -p 5000 -U "$PG_USER" -d postgres -t -c "SELECT pg_is_in_recovery();" 2>&1 | tr -d ' ')
check "NLB port 5000 routes to primary (pg_is_in_recovery = f)" "$write_recovery" "f"

read_recovery=$(PGPASSWORD="" psql -h "$NLB_DNS" -p 5001 -U "$PG_USER" -d postgres -t -c "SELECT pg_is_in_recovery();" 2>&1 | tr -d ' ')
check "NLB port 5001 routes to replica (pg_is_in_recovery = t)" "$read_recovery" "t"

# ─────────────────────────────────────────────────────────────────────────────
print_header "5. Replication Lag"
# ─────────────────────────────────────────────────────────────────────────────

repl_status=$(PGPASSWORD="" psql -h "$NLB_DNS" -p 5000 -U "$PG_USER" -d postgres -t -c \
    "SELECT client_addr, state, (sent_lsn - replay_lsn) AS lag_bytes FROM pg_stat_replication;" 2>&1)
echo "$repl_status"

replica_count=$(echo "$repl_status" | grep -c "streaming" || true)
check "At least 1 replica is in streaming replication" "$replica_count" "[1-9]"

# ─────────────────────────────────────────────────────────────────────────────
print_header "6. PgBackRest Backup Repositories"
# ─────────────────────────────────────────────────────────────────────────────

echo "  Running: pgbackrest check"
pgbackrest_check=$(sudo -u postgres pgbackrest --stanza="$STANZA" check 2>&1)
echo "$pgbackrest_check"
check "PgBackRest stanza check passes" "$pgbackrest_check" "completed successfully"

echo ""
echo "  Running: pgbackrest info"
sudo -u postgres pgbackrest --stanza="$STANZA" info 2>&1

# ─────────────────────────────────────────────────────────────────────────────
print_header "7. HAProxy Stats Pages Reachable"
# ─────────────────────────────────────────────────────────────────────────────

for node_ip in "$PG_NODE_1" "$PG_NODE_2" "$PG_NODE_3"; do
    stats_code=$(curl -s -o /dev/null -w "%{http_code}" "http://${node_ip}:7000/haproxy")
    check "HAProxy stats reachable on $node_ip" "$stats_code" "200"
done

# ─────────────────────────────────────────────────────────────────────────────
print_header "Summary"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "  ✅  All checks passed. Cluster is healthy."
    exit 0
else
    echo "  ❌  $FAIL check(s) failed. Review output above."
    exit 1
fi
