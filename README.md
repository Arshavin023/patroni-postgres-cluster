# Patroni PostgreSQL HA Cluster on AWS

A production-proven, battle-tested setup for a highly available PostgreSQL 17 cluster using **Patroni**, **ETCD**, **HAProxy**, and **PgBackRest** — deployed on AWS EC2 with an NLB for transparent client routing.

> This setup has been successfully implemented in a production AWS environment.  
> It is designed to be fully generic — adapt the placeholder values to your own infrastructure.

---

## Architecture

```
Client Application
        │
        ▼
  AWS Network Load Balancer
  ├── Port 5000  →  WRITES  (TCP, forwards to all 3 nodes)
  └── Port 5001  →  READS   (TCP, forwards to all 3 nodes)
        │
        │  NLB health-checks HAProxy on port 9000 (writes) and port 9001 (reads)
        │  HAProxy returns 200 only if the relevant backend is up on that node
        │  Removes any node where the backend is unavailable from NLB rotation
        ▼
  HAProxy  (co-located on every PostgreSQL node)
  ├── Port 5000  →  queries GET /primary on Patroni REST (port 8008) → routes to leader only
  ├── Port 5001  →  queries GET /replica on Patroni REST (port 8008) → round-robins across replicas
  │                 falls back to primary if no replicas are available
  ├── Port 9000  →  NLB health endpoint: 200 if primary backend is up on this node, else 503
  └── Port 9001  →  NLB health endpoint: 200 if read backend is up on this node, else 503
        │
        ▼
  PostgreSQL 17 on port 5432
```

### Node Layout

| Role | Count | Subnet |
|------|-------|--------|
| PostgreSQL + Patroni + HAProxy | 3 | `10.0.1.0/24` |
| ETCD | 3 (dedicated) | `10.0.2.0/24` |

### Key Design Decisions

- **Dedicated ETCD nodes** — keeps consensus traffic completely separate from database I/O
- **HAProxy co-located on each PG node** — no single point of failure in the routing layer; the NLB distributes to all three, and only the one with the current primary actually accepts writes
- **NLB health checks on ports 9000/9001** — the NLB hits HAProxy's dedicated health endpoints, not Patroni directly; HAProxy returns 200 only if the relevant backend (primary or replica) is actually up on that node, giving the NLB role-aware visibility rather than a simple port-open check
- **PgBackRest with `backup-standby=y`** — backup I/O hits a replica, keeping the write path clean
- **Dual backup repos** — S3 (warm) + MinIO (cold/off-site) for defence-in-depth

---

## Stack Versions

| Component | Version |
|-----------|---------|
| PostgreSQL | 17 |
| Patroni | latest (via pip, etcd3 extras) |
| ETCD | v3.5.12 |
| HAProxy | distro package (Ubuntu 24.04) |
| PgBackRest | distro package |

---

## Repository Layout

```
patroni-postgres-cluster/
├── README.md
├── .gitignore
│
├── docs/
│   └── architecture.md          # Deep-dive: failover flow, HAProxy logic, NLB setup
│
├── runbooks/
│   └── 01-cluster-setup.md      # Step-by-step build guide (Phases 1–9)
│
├── config/
│   ├── patroni/
│   │   ├── patroni.yml.example          # pg-node-1 (primary bootstrap)
│   │   └── patroni-replica.yml.example  # pg-node-2 / pg-node-3
│   ├── etcd/
│   │   └── etcd.conf.yml.example        # One template — change name/IPs per node
│   ├── haproxy/
│   │   └── haproxy.cfg.example          # HAProxy config (node-aware NLB health endpoints)
│   └── pgbackrest/
│       └── pgbackrest.conf.example      # Dual-repo: S3 + MinIO
│
└── scripts/
    └── verify-cluster.sh        # End-to-end health checks after deployment
```

---

## Quick Start

1. **Read** `docs/architecture.md` — understand the topology before touching anything
2. **Provision** 6 EC2 instances (3 for PostgreSQL, 3 for ETCD) in the same VPC, across two subnets
3. **Copy and adapt** the example configs — search-replace every `PLACEHOLDER_*` value
4. **Follow** `runbooks/01-cluster-setup.md` phase by phase — order matters
5. **Run** `scripts/verify-cluster.sh` to confirm the cluster is healthy

---

## Prerequisites

- Ubuntu 22.04 or 24.04 on all nodes
- AWS VPC with two private subnets (`10.0.1.0/24` for PG, `10.0.2.0/24` for ETCD)
- An AWS Network Load Balancer (internal)
- An S3 bucket for PgBackRest backups
- (Optional) A MinIO endpoint for a second cold backup repository
- IAM user with S3 read/write permissions on the backup bucket
- Security groups configured per `docs/architecture.md`

---

## Placeholder Reference

Before running anything, replace every occurrence of these placeholders:

| Placeholder | What to put here |
|-------------|-----------------|
| `PG_NODE_1_IP` | Private IP of your first PostgreSQL EC2 |
| `PG_NODE_2_IP` | Private IP of your second PostgreSQL EC2 |
| `PG_NODE_3_IP` | Private IP of your third PostgreSQL EC2 |
| `ETCD_NODE_1_IP` | Private IP of etcd-1 |
| `ETCD_NODE_2_IP` | Private IP of etcd-2 |
| `ETCD_NODE_3_IP` | Private IP of etcd-3 |
| `YOUR_NLB_DNS_NAME` | NLB DNS name from AWS console |
| `YOUR_CLUSTER_NAME` | Short name for your cluster (e.g. `myapp-postgres`) |
| `YOUR_STANZA_NAME` | PgBackRest stanza name (usually matches your app/db name) |
| `YOUR_S3_BUCKET` | S3 bucket name for primary backups |
| `YOUR_S3_REGION` | AWS region of the bucket |
| `YOUR_AWS_ACCESS_KEY_ID` | IAM access key for PgBackRest |
| `YOUR_AWS_SECRET_ACCESS_KEY` | IAM secret key for PgBackRest |
| `YOUR_MINIO_ENDPOINT` | MinIO host:port (omit repo2 block if not using MinIO) |
| `YOUR_MINIO_ACCESS_KEY` | MinIO access key |
| `YOUR_MINIO_SECRET_KEY` | MinIO secret key |
| `CHANGE_ME_REPLICATOR_PASSWORD` | Password for the `replicator` streaming replication user |
| `CHANGE_ME_POSTGRES_PASSWORD` | Password for the `postgres` superuser |
| `CHANGE_ME_REWIND_PASSWORD` | Password for the `rewind_user` (pg_rewind after failover) |
| `CHANGE_ME_ADMIN_PASSWORD` | Password for the `admin` application user |
| `CHANGE_ME_CIPHER_PASSPHRASE` | AES-256 passphrase for S3 backup encryption |
| `CHANGE_ME_MINIO_CIPHER_PASSPHRASE` | AES-256 passphrase for MinIO backup encryption |
| `YOUR_VPC_ID` | AWS VPC ID |
| `YOUR_PG_EC2_INSTANCE_IDS` | EC2 instance IDs for the 3 PostgreSQL nodes |

---

## Failover Behaviour

| Event | Recovery time | Action required |
|-------|--------------|----------------|
| Patroni process crash | ~30 s (TTL) | None — auto-elected |
| EC2 instance failure | ~30–60 s | None — NLB removes node, Patroni elects new leader |
| Graceful switchover | ~10 s | `patronictl switchover` |
| Network partition | TTL dependent | None if quorum holds |

---

## License

MIT — use freely, attribution appreciated.
