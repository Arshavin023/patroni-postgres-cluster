# Architecture Deep Dive

## Topology Overview

This cluster uses a **6-node architecture** split across two dedicated subnets:

```
VPC
├── Subnet 10.0.1.0/24  — PostgreSQL nodes
│   ├── pg-node-1   (Primary bootstrap node)
│   ├── pg-node-2   (Replica / potential leader)
│   └── pg-node-3   (Replica / potential leader)
│
└── Subnet 10.0.2.0/24  — ETCD nodes
    ├── etcd-1
    ├── etcd-2
    └── etcd-3
```

Separating ETCD onto dedicated nodes and a dedicated subnet eliminates disk I/O contention. ETCD is extremely latency-sensitive — sharing a disk with PostgreSQL WAL writes is a known cause of false leader elections.

---

## Traffic Flow

### Write path (port 5000)

```
App → NLB:5000 → HAProxy:5000 on ALL 3 nodes
                      │
                      │  HAProxy calls GET /primary on Patroni REST (port 8008)
                      │  Only the current leader returns HTTP 200
                      │  All replicas return HTTP 503
                      ▼
               PostgreSQL:5432 on the current leader ONLY
```

### Read path (port 5001)

```
App → NLB:5001 → HAProxy:5001 on ALL 3 nodes
                      │
                      │  HAProxy calls GET /replica on Patroni REST (port 8008)
                      │  Active replicas return HTTP 200
                      │  Leader returns HTTP 503 for /replica
                      │  If NO replicas available → falls back to /primary
                      ▼
               PostgreSQL:5432 on replicas (round-robin)
               OR primary if all replicas are down
```

---

## Component Roles

### Patroni

Patroni wraps PostgreSQL and manages the leader election lifecycle:

- Registers itself with ETCD on startup and acquires a leader lock
- Continuously renews the lock (TTL = 30 s by default)
- Exposes a REST API on port 8008:
  - `GET /primary` → 200 if this node is the leader, 503 otherwise
  - `GET /replica` → 200 if this node is a healthy replica, 503 otherwise
  - `GET /health`  → 200 if Patroni itself is running
- If a node loses its ETCD lock (crash, network partition, etc.), the remaining nodes hold an election and the candidate with the least replication lag wins

### ETCD

Acts as the distributed consensus store. Patroni uses ETCD to:

- Store the cluster state (who is the current leader)
- Coordinate leader elections via distributed locks
- Propagate DCS (Distributed Configuration Store) settings to all nodes

A 3-node ETCD cluster can tolerate **1 node failure** while maintaining quorum.

### HAProxy

Runs co-located on every PostgreSQL node. This is intentional — there is no dedicated HAProxy tier to fail.

- Polls Patroni's REST API every 3 seconds (`inter 3s`)
- Marks a backend DOWN after 3 consecutive failures (`fall 3`) — maximum detection time: **9 seconds**
- Marks a backend UP after 2 consecutive successes (`rise 2`)
- `on-marked-down shutdown-sessions` — drops existing connections to a failed backend immediately rather than letting them hang

The write backend (`primary_node`) only ever has one active server — the current Patroni leader. All other nodes are checked but return 503 from `/primary`, so HAProxy never routes writes to them.

### AWS NLB

Layer 4 (TCP) load balancer. Its role is distribution and coarse-grained health checking:

- Distributes incoming TCP connections across all 3 PostgreSQL EC2 nodes
- Health checks **port 8008 over HTTP** — confirms Patroni is alive on that node
- If Patroni crashes on a node (but HAProxy is still up), the NLB removes that node from its pool
- Does NOT do primary/replica routing — that is entirely HAProxy's job

This two-layer design means:
- NLB handles node-level availability (is this EC2 reachable and is Patroni running?)
- HAProxy handles cluster-role routing (is this node the current primary or a replica?)

---

## Failover Sequence

1. Primary (pg-node-1) crashes or loses network
2. Patroni on pg-node-1 stops renewing its ETCD leader lock
3. After TTL expires (~30 s), ETCD releases the lock
4. Patroni on pg-node-2 and pg-node-3 detect the lock is free and hold an election
5. The node with the smallest replication lag wins and acquires the lock
6. Winning node promotes itself: `pg_ctl promote`
7. Patroni REST API on the new leader now returns 200 for `GET /primary`
8. HAProxy detects the change within 3–9 seconds and redirects writes to the new leader
9. NLB continues operating — it health-checks 8008 and both surviving nodes pass
10. When pg-node-1 recovers, Patroni on that node detects it is no longer the leader, demotes PostgreSQL to a standby, and re-joins as a replica using `pg_rewind`

**Total client-facing write outage: approximately 30–60 seconds** (TTL + HAProxy detection + PostgreSQL promotion).

---

## PgBackRest Design

### Why `backup-standby=y`

Full backups are large I/O operations. Running the file copy phase from a replica keeps backup load off the primary write path entirely. Patroni coordinates `pg_backup_start()` and `pg_backup_stop()` via `pg1-host` (the NLB write endpoint), which always resolves to the current leader — so backups survive failovers without config changes.

### Dual Repository Strategy

| Repo | Type | Purpose | Retention |
|------|------|---------|-----------|
| repo1 | AWS S3 | Primary warm backup | 2 full, 4 diff, 14 days WAL |
| repo2 | MinIO | Cold/off-site backup | 1 full |

Both repositories are written to on every backup. If S3 is unavailable, you can restore from MinIO, and vice versa.

### WAL Archiving (`archive-async=y`)

WAL segments are spooled locally at `/var/spool/pgbackrest` before being pushed to S3 asynchronously. This prevents S3 latency spikes from blocking PostgreSQL commits. The spool directory acts as a buffer — WAL is never lost even if S3 is temporarily unreachable.

---

## Port Reference

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 5432 | TCP | Internal | PostgreSQL native |
| 8008 | TCP/HTTP | Internal + NLB | Patroni REST API |
| 5000 | TCP | NLB → HAProxy | Write endpoint |
| 5001 | TCP | NLB → HAProxy | Read endpoint |
| 7000 | HTTP | Internal only | HAProxy stats dashboard |
| 9000 | HTTP | NLB health check | HAProxy write pool health |
| 9001 | HTTP | NLB health check | HAProxy read pool health |
| 2379 | TCP | PG nodes → ETCD | ETCD client |
| 2380 | TCP | ETCD → ETCD | ETCD peer election |

---

## AWS Security Group Rules

### PostgreSQL Security Group

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 5432 | TCP | VPC CIDR | PostgreSQL |
| 8008 | TCP | VPC CIDR + NLB SG | Patroni REST (HAProxy + NLB health checks) |
| 5000 | TCP | NLB SG | HAProxy writes |
| 5001 | TCP | NLB SG | HAProxy reads |
| 7000 | TCP | VPC CIDR (internal) | HAProxy stats |
| 9000 | TCP | NLB SG | NLB write health endpoint |
| 9001 | TCP | NLB SG | NLB read health endpoint |
| 22   | TCP | Bastion IP | SSH |

### ETCD Security Group

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 2379 | TCP | PostgreSQL SG | Patroni → ETCD client |
| 2380 | TCP | ETCD SG | ETCD peer election |
| 22   | TCP | Bastion IP | SSH |

> Never expose ETCD ports to the public internet. Port 2379 should only accept connections from the PostgreSQL subnet.

---

## Operational Tuning Notes

### PostgreSQL parameters (set in Patroni DCS bootstrap)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `shared_buffers` | 25% of RAM | Standard PostgreSQL recommendation |
| `effective_cache_size` | 75% of RAM | Planner hint — not allocated |
| `work_mem` | 32 MB | Per-sort, per-hash — multiply by `max_connections` for worst-case |
| `wal_level` | `replica` | Required for streaming replication and PgBackRest archiving |
| `max_wal_senders` | 10 | Headroom for replication slots + PgBackRest |
| `checkpoint_completion_target` | 0.9 | Spreads checkpoint I/O over 90% of the checkpoint interval |
| `archive_mode` | `on` | Required for PgBackRest WAL archiving |

### ETCD tuning (small instances)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `heartbeat-interval` | 100 ms | Default; safe for same-region VPC latency |
| `election-timeout` | 1000 ms | 10× heartbeat — required minimum |
| `quota-backend-bytes` | 1 GB | Hard cap; prevents ETCD from consuming all disk |
| `vm.swappiness` | 0 | Prevents kernel from swapping ETCD pages — reduces latency spikes |
| `IOSchedulingClass` | realtime | Gives ETCD fsync priority over other processes |
