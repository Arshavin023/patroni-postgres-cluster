# Runbook 01 — Patroni PostgreSQL Cluster Setup

**Stack:** PostgreSQL 17 · Patroni · ETCD v3.5.12 · HAProxy · PgBackRest  
**Target OS:** Ubuntu 22.04 / 24.04  
**Platform:** AWS EC2

> Replace every `PLACEHOLDER_*` value and every IP address with your own before running.  
> See `README.md` for the full placeholder reference table.

---

## Node Reference

| Role | Hostname | Private IP | Recommended Spec |
|------|----------|------------|-----------------|
| PostgreSQL Primary | `pg-node-1` | `PG_NODE_1_IP` | m5.xlarge or larger |
| PostgreSQL Replica 1 | `pg-node-2` | `PG_NODE_2_IP` | Same as primary |
| PostgreSQL Replica 2 | `pg-node-3` | `PG_NODE_3_IP` | Same as primary |
| ETCD Node 1 | `etcd-1` | `ETCD_NODE_1_IP` | t3.small (2 GB RAM) |
| ETCD Node 2 | `etcd-2` | `ETCD_NODE_2_IP` | t3.small (2 GB RAM) |
| ETCD Node 3 | `etcd-3` | `ETCD_NODE_3_IP` | t3.small (2 GB RAM) |
| AWS NLB writes | — | Port `5000` | — |
| AWS NLB reads | — | Port `5001` | — |

---

## Phase 1 — Base Preparation: PostgreSQL Nodes (`pg-node-1`, `pg-node-2`, `pg-node-3`)

Run on **all three PostgreSQL nodes** unless otherwise noted.

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Set hostname — run the matching line on each node
sudo hostnamectl set-hostname pg-node-1   # on pg-node-1
sudo hostnamectl set-hostname pg-node-2   # on pg-node-2
sudo hostnamectl set-hostname pg-node-3   # on pg-node-3

# Add all 6 nodes to /etc/hosts on every PostgreSQL node
sudo tee -a /etc/hosts <<EOF
PG_NODE_1_IP    pg-node-1
PG_NODE_2_IP    pg-node-2
PG_NODE_3_IP    pg-node-3
ETCD_NODE_1_IP  etcd-1
ETCD_NODE_2_IP  etcd-2
ETCD_NODE_3_IP  etcd-3
EOF

# Install dependencies
sudo apt install -y \
    curl wget gnupg2 lsb-release \
    python3 python3-pip python3-dev \
    libpq-dev gcc git jq net-tools

# Add PostgreSQL apt repository
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg

echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update

# Install PostgreSQL 17
sudo apt install -y postgresql-17 postgresql-client-17 postgresql-contrib-17

# Disable the native PostgreSQL service — Patroni manages it exclusively
sudo systemctl stop postgresql
sudo systemctl disable postgresql

# Verify the postgres OS user exists
id postgres
```

### Install Patroni in an Isolated Virtual Environment

```bash
sudo apt install -y python3-venv python3-full

# Create a standardised global directory for the Patroni environment
sudo python3 -m venv /opt/patroni-venv

# Upgrade pip and install Patroni with ETCD3 and Postgres support
sudo /opt/patroni-venv/bin/pip install --upgrade pip
sudo /opt/patroni-venv/bin/pip install patroni[etcd3] psycopg2-binary

# Create global symlinks
sudo ln -sf /opt/patroni-venv/bin/patroni /usr/local/bin/patroni
sudo ln -sf /opt/patroni-venv/bin/patronictl /usr/local/bin/patronictl

# Verify
patroni --version
patronictl --help
```

### Install HAProxy

```bash
sudo apt install -y haproxy
haproxy -v
```

### Create Required Directories

```bash
sudo mkdir -p /etc/patroni /var/log/patroni /data/patroni
sudo chown postgres:postgres /data/patroni /var/log/patroni
sudo chmod 700 /data/patroni

# Ensure pg_ctl is on PATH for PostgreSQL 17
which pg_ctl || sudo ln -s /usr/lib/postgresql/17/bin/pg_ctl /usr/local/bin/pg_ctl
pg_ctl --version
```

---

## Phase 2 — ETCD Setup: Dedicated ETCD Nodes (`etcd-1`, `etcd-2`, `etcd-3`)

### 2a — Base Preparation (all 3 ETCD nodes)

```bash
sudo apt update && sudo apt upgrade -y

# Set hostname — run the matching line on each node
sudo hostnamectl set-hostname etcd-1   # on etcd-1
sudo hostnamectl set-hostname etcd-2   # on etcd-2
sudo hostnamectl set-hostname etcd-3   # on etcd-3

# Add all 6 nodes to /etc/hosts
sudo tee -a /etc/hosts <<EOF
PG_NODE_1_IP    pg-node-1
PG_NODE_2_IP    pg-node-2
PG_NODE_3_IP    pg-node-3
ETCD_NODE_1_IP  etcd-1
ETCD_NODE_2_IP  etcd-2
ETCD_NODE_3_IP  etcd-3
EOF

sudo apt install -y curl wget jq net-tools

# Create etcd OS user
sudo useradd -r -s /sbin/nologin etcd 2>/dev/null || true

# Create data and config directories
sudo mkdir -p /var/lib/etcd /etc/etcd
sudo chown -R etcd:etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd

# Download ETCD v3.5.12 binaries
ETCD_VER=v3.5.12
wget https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar -xzf etcd-${ETCD_VER}-linux-amd64.tar.gz
sudo mv etcd-${ETCD_VER}-linux-amd64/etcd /usr/local/bin/
sudo mv etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
rm -rf etcd-${ETCD_VER}-linux-amd64*

etcd --version
etcdctl version

# Kernel tuning — critical on small instances
sudo tee -a /etc/sysctl.conf <<EOF
# ETCD I/O tuning
vm.swappiness=0
net.core.rmem_max=2500000
EOF
sudo sysctl -p
```

### 2b — (Optional) Dedicated SSD Volume for ETCD Data

ETCD is extremely sensitive to disk latency. On AWS, attach a separate **gp3 SSD** to each ETCD node and mount it at `/var/lib/etcd`.

```bash
# Identify the attached device
lsblk

# Format and mount — replace /dev/nvme1n1 with your actual device
sudo mkfs.ext4 /dev/nvme1n1
sudo mount /dev/nvme1n1 /var/lib/etcd
sudo chown etcd:etcd /var/lib/etcd

# Make mount permanent
echo "/dev/nvme1n1  /var/lib/etcd  ext4  defaults,noatime  0 2" \
    | sudo tee -a /etc/fstab
```

### 2c — ETCD Configuration

Each node gets its own config. Replace `ETCD_NODE_N_IP` with the actual IP for that node.

The example file at `config/etcd/etcd.conf.yml.example` contains the template — copy it to `/etc/etcd/etcd.conf.yml` on each node and substitute:
- `name`: `etcd-1` / `etcd-2` / `etcd-3`
- `listen-client-urls` / `advertise-client-urls` / `listen-peer-urls` / `initial-advertise-peer-urls`: this node's IP
- `initial-cluster`: all three nodes (always the same on all three configs)

```bash
# Copy template and edit on each ETCD node
sudo cp /path/to/repo/config/etcd/etcd.conf.yml.example /etc/etcd/etcd.conf.yml
sudo nano /etc/etcd/etcd.conf.yml
sudo chown etcd:etcd /etc/etcd/etcd.conf.yml
sudo chmod 640 /etc/etcd/etcd.conf.yml
```

### 2d — ETCD systemd Service (all 3 ETCD nodes)

```bash
sudo tee /etc/etcd/etcd.env <<'EOF'
# Add TLS cert paths here if you enable TLS later
# ETCD_PEER_CERT_FILE=/etc/etcd/certs/peer.crt
# ETCD_PEER_KEY_FILE=/etc/etcd/certs/peer.key
EOF

sudo chown etcd:etcd /etc/etcd/etcd.env
sudo chmod 640 /etc/etcd/etcd.env

sudo tee /etc/systemd/system/etcd.service <<'EOF'
[Unit]
Description=ETCD Key-Value Store
Documentation=https://etcd.io/docs
After=network.target

[Service]
Type=notify
User=etcd
Group=etcd
EnvironmentFile=-/etc/etcd/etcd.env
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
IOSchedulingClass=realtime
IOSchedulingPriority=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
sudo systemctl status etcd
```

### 2e — Verify ETCD Cluster Health

Run from any ETCD node. Expected: 3 members, 1 leader, 2 followers, all healthy.

```bash
ETCD_ENDPOINTS="http://ETCD_NODE_1_IP:2379,http://ETCD_NODE_2_IP:2379,http://ETCD_NODE_3_IP:2379"

etcdctl --endpoints=$ETCD_ENDPOINTS endpoint health --write-out=table
etcdctl --endpoints=$ETCD_ENDPOINTS endpoint status --write-out=table
etcdctl --endpoints=$ETCD_ENDPOINTS member list --write-out=table
```

---

## Phase 3 — Configure Patroni (PostgreSQL Nodes)

Each PostgreSQL node needs its own `/etc/patroni/patroni.yml`. The only differences between nodes are:
- `name`: `pg-node-1` / `pg-node-2` / `pg-node-3`
- `restapi.listen` / `restapi.connect_address`: this node's IP
- `postgresql.listen` / `postgresql.connect_address`: this node's IP

The `bootstrap` block (DCS settings, `initdb`, `pg_hba`, users) is only used when the cluster is first created — it only needs to be correct on `pg-node-1` but including it on all nodes is safe.

```bash
# Copy and adapt on each PostgreSQL node
sudo cp /path/to/repo/config/patroni/patroni.yml.example /etc/patroni/patroni.yml
# Edit all PLACEHOLDER_ values and the node-specific IP addresses
sudo nano /etc/patroni/patroni.yml

# Lock down file permissions — this file contains database passwords
sudo chown postgres:postgres /etc/patroni/patroni.yml
sudo chmod 600 /etc/patroni/patroni.yml
```

### Patroni systemd Service (all 3 PostgreSQL nodes)

```bash
sudo tee /etc/systemd/system/patroni.service <<'EOF'
[Unit]
Description=Patroni — PostgreSQL HA Cluster Manager
After=syslog.target network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/opt/patroni-venv/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure
StandardOutput=append:/var/log/patroni/patroni.log
StandardError=append:/var/log/patroni/patroni.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable patroni
```

### Start Patroni — Order Matters

```bash
# 1. Confirm ETCD is healthy first
etcdctl --endpoints=http://ETCD_NODE_1_IP:2379,http://ETCD_NODE_2_IP:2379,http://ETCD_NODE_3_IP:2379 endpoint health

# 2. Start pg-node-1 FIRST — bootstraps the cluster and elects itself leader
# On pg-node-1:
sudo systemctl start patroni
sudo systemctl status patroni

# Wait 15–20 seconds, then verify it elected itself leader
patronictl -c /etc/patroni/patroni.yml list

# 3. Start pg-node-2
# On pg-node-2:
sudo systemctl start patroni

# 4. Start pg-node-3
# On pg-node-3:
sudo systemctl start patroni

# Final check — should show 1 Leader + 2 Replicas, replication Lag = 0
patronictl -c /etc/patroni/patroni.yml list
```

---

## Phase 4 — HAProxy Configuration (PostgreSQL Nodes)

HAProxy is already installed from Phase 1. Each node gets a config that is identical in structure but references **itself** in the NLB health check frontends.

See `config/haproxy/haproxy.cfg.example` — note the node-specific lines in the NLB health check frontends at the bottom. Update these to reference the correct node name.

```bash
sudo cp /path/to/repo/config/haproxy/haproxy.cfg.example /etc/haproxy/haproxy.cfg
# Edit the node-specific server IPs and NLB health check server names
sudo nano /etc/haproxy/haproxy.cfg

sudo systemctl enable haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy
```

### Verify HAProxy is Routing Correctly

```bash
# Check HAProxy is listening
ss -tlnp | grep -E '5000|5001|7000'

# Check Patroni health endpoints — only the leader returns 200 for /primary
curl -s -o /dev/null -w "%{http_code}\n" http://PG_NODE_1_IP:8008/primary
curl -s -o /dev/null -w "%{http_code}\n" http://PG_NODE_2_IP:8008/primary
curl -s -o /dev/null -w "%{http_code}\n" http://PG_NODE_3_IP:8008/primary

# Check HAProxy stats dashboard in a browser
# http://PG_NODE_1_IP:7000/haproxy
```

---

## Phase 5 — AWS NLB Configuration

### Create Target Groups

```bash
# Writes target group (port 5000)
aws elbv2 create-target-group \
  --name pg-writes-tg \
  --protocol TCP \
  --port 5000 \
  --vpc-id YOUR_VPC_ID \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port 9000 \
  --health-check-path / \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2

# Reads target group (port 5001)
aws elbv2 create-target-group \
  --name pg-reads-tg \
  --protocol TCP \
  --port 5001 \
  --vpc-id YOUR_VPC_ID \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port 9001 \
  --health-check-path / \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2

# Register all 3 PostgreSQL EC2 instances in both target groups
aws elbv2 register-targets \
  --target-group-arn <writes-tg-arn> \
  --targets Id=<ec2-id-1> Id=<ec2-id-2> Id=<ec2-id-3>

aws elbv2 register-targets \
  --target-group-arn <reads-tg-arn> \
  --targets Id=<ec2-id-1> Id=<ec2-id-2> Id=<ec2-id-3>

# Create listeners
aws elbv2 create-listener \
  --load-balancer-arn <nlb-arn> \
  --protocol TCP --port 5000 \
  --default-actions Type=forward,TargetGroupArn=<writes-tg-arn>

aws elbv2 create-listener \
  --load-balancer-arn <nlb-arn> \
  --protocol TCP --port 5001 \
  --default-actions Type=forward,TargetGroupArn=<reads-tg-arn>
```

### Application Connection Strings

```
# Writes — always reaches the current primary via HAProxy
postgresql://user:password@YOUR_NLB_DNS_NAME:5000/your_database

# Reads — load-balanced across replicas via HAProxy
postgresql://user:password@YOUR_NLB_DNS_NAME:5001/your_database
```

> The NLB health check uses HTTP on port 8008 (Patroni REST) — not TCP on 5000.  
> This is intentional: it verifies Patroni is alive, not just that HAProxy's port is open.  
> If Patroni crashes but HAProxy stays up, the NLB correctly removes that node from rotation.

---

## Phase 6 — PgBackRest (PostgreSQL Nodes)

### Install

```bash
# On all 3 PostgreSQL nodes
sudo apt install -y pgbackrest
pgbackrest version
```

### IAM and S3 Setup

```bash
# Create a dedicated IAM user for PgBackRest
aws iam create-user --user-name pgbackrest-s3-user

aws iam put-user-policy \
  --user-name pgbackrest-s3-user \
  --policy-name PgBackRestS3Policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket",
        "s3:GetBucketLocation","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::YOUR_S3_BUCKET",
        "arn:aws:s3:::YOUR_S3_BUCKET/*"
      ]
    }]
  }'

# Save the keys printed by this command — you will not see the secret again
aws iam create-access-key --user-name pgbackrest-s3-user

# Create and harden the S3 bucket
aws s3api create-bucket \
  --bucket YOUR_S3_BUCKET \
  --region YOUR_S3_REGION \
  --create-bucket-configuration LocationConstraint=YOUR_S3_REGION

aws s3api put-bucket-versioning \
  --bucket YOUR_S3_BUCKET \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket YOUR_S3_BUCKET \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,\
    BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### PgBackRest Configuration (all 3 PostgreSQL nodes)

```bash
sudo mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
sudo chown postgres:postgres /var/log/pgbackrest /var/spool/pgbackrest

sudo cp /path/to/repo/config/pgbackrest/pgbackrest.conf.example /etc/pgbackrest/pgbackrest.conf
# Edit all PLACEHOLDER_ values — particularly the S3 keys and stanza name
sudo nano /etc/pgbackrest/pgbackrest.conf

sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
sudo chmod 640 /etc/pgbackrest/pgbackrest.conf
```

### SSH Key Exchange Between PostgreSQL Nodes

PgBackRest requires passwordless SSH between PostgreSQL nodes to copy files from replicas during `backup-standby=y`.

```bash
# Generate key on ALL 3 PostgreSQL nodes (run as postgres)
sudo -u postgres ssh-keygen -t rsa -b 4096 -N '' \
    -f /var/lib/postgresql/.ssh/id_rsa

# From pg-node-1: push public key to pg-node-2 and pg-node-3
sudo -u postgres ssh-copy-id postgres@PG_NODE_2_IP
sudo -u postgres ssh-copy-id postgres@PG_NODE_3_IP

# From pg-node-2: push to pg-node-1 and pg-node-3
sudo -u postgres ssh-copy-id postgres@PG_NODE_1_IP
sudo -u postgres ssh-copy-id postgres@PG_NODE_3_IP

# From pg-node-3: push to pg-node-1 and pg-node-2
sudo -u postgres ssh-copy-id postgres@PG_NODE_1_IP
sudo -u postgres ssh-copy-id postgres@PG_NODE_2_IP

# Verify passwordless SSH works
sudo -u postgres ssh postgres@PG_NODE_2_IP "echo SSH OK"
```

### Initialise Stanza and First Backup (pg-node-1 only)

Run after the Patroni cluster is fully up and healthy.

```bash
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME stanza-create
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME check

# Take the first full backup
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME --type=full backup

# Confirm backup stored in both repos
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME info
```

### Backup Cron Schedule (all 3 PostgreSQL nodes)

```bash
sudo -u postgres crontab -e

# Full backup every Sunday at 01:00 — only executes on the active Patroni leader
0 1 * * 0  patronictl -c /etc/patroni/patroni.yml list | grep -q "$(hostname).*Leader" && pgbackrest --stanza=YOUR_STANZA_NAME --type=full backup >> /var/log/pgbackrest/cron.log 2>&1

# Differential Mon–Sat at 01:00
0 1 * * 1-6  patronictl -c /etc/patroni/patroni.yml list | grep -q "$(hostname).*Leader" && pgbackrest --stanza=YOUR_STANZA_NAME --type=diff backup >> /var/log/pgbackrest/cron.log 2>&1

# Incremental every 6 hours
0 */6 * * *  patronictl -c /etc/patroni/patroni.yml list | grep -q "$(hostname).*Leader" && pgbackrest --stanza=YOUR_STANZA_NAME --type=incr backup >> /var/log/pgbackrest/cron.log 2>&1
```

---

## Phase 7 — Firewall Rules

### PostgreSQL Nodes — UFW

```bash
sudo ufw allow from 10.0.1.0/24 to any port 5432 proto tcp   # PostgreSQL
sudo ufw allow from 10.0.1.0/24 to any port 8008 proto tcp   # Patroni REST API
sudo ufw allow from 10.0.1.0/24 to any port 5000 proto tcp   # HAProxy writes
sudo ufw allow from 10.0.1.0/24 to any port 5001 proto tcp   # HAProxy reads
sudo ufw allow from 10.0.1.0/24 to any port 7000 proto tcp   # HAProxy stats (internal only)
sudo ufw allow from 10.0.1.0/24 to any port 22   proto tcp   # SSH
sudo ufw --force enable
```

### ETCD Nodes — UFW

```bash
sudo ufw allow from 10.0.2.0/24 to any port 2380 proto tcp   # ETCD peer
sudo ufw allow from 10.0.1.0/24 to any port 2379 proto tcp   # ETCD client (Patroni)
sudo ufw allow from 10.0.2.0/24 to any port 2379 proto tcp   # ETCD client (local)
sudo ufw allow from 10.0.1.0/24 to any port 22   proto tcp   # SSH
sudo ufw --force enable
```

---

## Phase 8 — Operational Commands

```bash
# Cluster status
patronictl -c /etc/patroni/patroni.yml list
patronictl -c /etc/patroni/patroni.yml topology

# Graceful switchover (zero data loss — preferred for planned maintenance)
patronictl -c /etc/patroni/patroni.yml switchover \
    --master pg-node-1 --candidate pg-node-2 --scheduled now --force

# Emergency failover (use only when primary is unreachable)
patronictl -c /etc/patroni/patroni.yml failover \
    YOUR_CLUSTER_NAME --master pg-node-1 --candidate pg-node-2 --force

# Reinitialise a lagging or diverged replica
patronictl -c /etc/patroni/patroni.yml reinit \
    YOUR_CLUSTER_NAME pg-node-3

# Pause and resume auto-failover (use during maintenance windows)
patronictl -c /etc/patroni/patroni.yml pause
patronictl -c /etc/patroni/patroni.yml resume

# Restore latest backup
sudo systemctl stop patroni
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME --delta restore
sudo systemctl start patroni

# Point-in-time restore
sudo systemctl stop patroni
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME \
    --type=time "--target=2026-01-15 03:00:00" --delta restore
sudo systemctl start patroni

# View logs
tail -f /var/log/patroni/patroni.log
tail -f /var/log/pgbackrest/pgbackrest.log
journalctl -u etcd -f          # on ETCD nodes
journalctl -u haproxy -f
```

---

## Phase 9 — Verification Checklist

Run `scripts/verify-cluster.sh` for an automated check, or run these manually:

```bash
# 1. ETCD cluster: 3 members, 1 leader, 2 followers
etcdctl --endpoints=http://ETCD_NODE_1_IP:2379,http://ETCD_NODE_2_IP:2379,http://ETCD_NODE_3_IP:2379 \
    endpoint status --write-out=table

# 2. Patroni: 1 Leader + 2 Replicas, Lag = 0
patronictl -c /etc/patroni/patroni.yml list

# 3. Writes go to primary (pg_is_in_recovery = f)
psql -h YOUR_NLB_DNS_NAME -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"

# 4. Reads go to replica (pg_is_in_recovery = t)
psql -h YOUR_NLB_DNS_NAME -p 5001 -U postgres -c "SELECT pg_is_in_recovery();"

# 5. Replication lag near zero
psql -h PG_NODE_1_IP -p 5432 -U postgres -c \
    "SELECT client_addr, state, (sent_lsn - replay_lsn) AS lag_bytes
     FROM pg_stat_replication;"

# 6. PgBackRest healthy on both repos
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME check
sudo -u postgres pgbackrest --stanza=YOUR_STANZA_NAME info

# 7. Failover test — writes follow the new leader automatically
patronictl -c /etc/patroni/patroni.yml switchover \
    --master pg-node-1 --candidate pg-node-2 --scheduled now --force
sleep 15
psql -h YOUR_NLB_DNS_NAME -p 5000 -U postgres -c "SELECT pg_is_in_recovery();"
# Must still return: f
```

---

## Appendix — Pre-Launch Secrets Checklist

Search for any remaining placeholders before going live:

```bash
grep -r "PLACEHOLDER\|CHANGE_ME\|YOUR_" /etc/patroni/ /etc/pgbackrest/ /etc/etcd/
```

| Item | Location | Notes |
|------|----------|-------|
| `replicator` password | patroni.yml | Used for streaming replication |
| `postgres` superuser password | patroni.yml | Guard carefully |
| `rewind_user` password | patroni.yml | Used by pg_rewind after failover |
| `admin` user password | patroni.yml bootstrap | Application admin user |
| S3 access key + secret | pgbackrest.conf | Use IAM role on EC2 if possible |
| S3 cipher passphrase | pgbackrest.conf | Keep an offline copy — loss = unrecoverable backups |
| MinIO access key + secret | pgbackrest.conf | If using MinIO repo |
| MinIO cipher passphrase | pgbackrest.conf | Keep an offline copy |
| ETCD cluster token | etcd.conf.yml | Should be unique per cluster |
