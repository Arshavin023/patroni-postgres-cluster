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

```bash
# Set hostname — run the matching line on each node
sudo hostnamectl set-hostname pg-node-1   # on pg-node-1
sudo hostnamectl set-hostname pg-node-2   # on pg-node-2
sudo hostnamectl set-hostname pg-node-3   # on pg-node-3
```

### 1.1 Run on **all three PostgreSQL nodes** unless otherwise noted.

```bash
# Update system
sudo apt update && sudo apt upgrade -y

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

### 1.2 Install Patroni in an Isolated Virtual Environment in all three nodes

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

### 1.3 Install HAProxy in all three nodes

```bash
sudo apt install -y haproxy
haproxy -v
sudo mkdir -p /etc/patroni /var/log/patroni /data/patroni
sudo chown postgres:postgres /data/patroni /var/log/patroni
sudo chmod 700 /data/patroni

# Ensure pg_ctl is on PATH for PostgreSQL 17
which pg_ctl || sudo ln -s /usr/lib/postgresql/17/bin/pg_ctl /usr/local/bin/pg_ctl
pg_ctl --version
```

---


## Phase 2 — ETCD Setup: Dedicated ETCD Nodes (`etcd-1`, `etcd-2`, `etcd-3`)
```bash
# Set hostname — run the matching line on each node
sudo hostnamectl set-hostname etcd-1   # on etcd-1
sudo hostnamectl set-hostname etcd-2   # on etcd-2
sudo hostnamectl set-hostname etcd-3   # on etcd-3
```

### 2.1 — Base Preparation (all 3 ETCD nodes)

```bash
sudo apt update && sudo apt upgrade -y

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

### 2.2 — (Optional) Dedicated SSD Volume for ETCD Data

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

### 2.3 — ETCD Configuration

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

### 2.4 — ETCD systemd Service (all 3 ETCD nodes)

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

### 2.5 — Verify ETCD Cluster Health

Run from any ETCD node. Expected: 3 members, 1 leader, 2 followers, all healthy.

```bash
ETCD_ENDPOINTS="http://ETCD_NODE_1_IP:2379,http://ETCD_NODE_2_IP:2379,http://ETCD_NODE_3_IP:2379"

etcdctl --endpoints=$ETCD_ENDPOINTS endpoint health --write-out=table
etcdctl --endpoints=$ETCD_ENDPOINTS endpoint status --write-out=table
etcdctl --endpoints=$ETCD_ENDPOINTS member list --write-out=table
```

---

## Phase 3 — Configure Patroni (PostgreSQL Nodes)

### 3.1 — Patroni Configuration
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

### 3.2 Patroni systemd Service (all 3 PostgreSQL nodes)

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

### 3.3 Start Patroni — Order Matters

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
### 4.1 — HAProxy Configuration
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

### 4.2 Verify HAProxy is Routing Correctly

```bash
# Check HAProxy is listening
ss -tlnp | grep -E '5000|5001|7000'

pg_isready -h 127.0.0.1 -p 5000 && pg_isready -h 127.0.0.1 -p 5001
# Expected: 127.0.0.1:5000 - accepting connections
# (This traffic goes through HAProxy to local Postgres on 5432)

pg_isready -h 127.0.0.1 -p 5001
# Expected: 127.0.0.1:5001 - accepting connections
# (This traffic goes through HAProxy, across the network, to pg-node-2 on 5432)

# Verify HAProxy is correctly reading Patroni health endpoints
# Run after Patroni cluster is up — should show 200 on leader, 503 on replicas
curl -s -o /dev/null -w "%{http_code}\n" http://172.31.10.62:8008/primary
curl -s -o /dev/null -w "%{http_code}\n" http://172.31.37.150:8008/primary

curl -s -o /dev/null -w "%{http_code}\n" http://172.31.10.62:8008/replica
curl -s -o /dev/null -w "%{http_code}\n" http://172.31.37.150:8008/replica

curl -s -o /dev/null -w "%{http_code}" http://10.0.1.12:8008/primary

# Only one node should return 200 — that is your current primary
# Access the HAProxy stats dashboard in a browser: http://172.31.10.62:7000/haproxy
```

---

## Phase 5 — AWS NLB Configuration

### 5.1 Create Target Groups

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

### 5.3 Application Connection Strings on Application Server

```
# Writes — always reaches the current primary via HAProxy
postgresql://user:password@YOUR_NLB_DNS_NAME:5000/your_database

# Reads — load-balanced across replicas via HAProxy
postgresql://user:password@YOUR_NLB_DNS_NAME:5001/your_database
```

> Why HTTP health checks on ports 9000 and 9001, not TCP on 5432 or 5000?
> TCP on port 5432 (PostgreSQL) or 5000 (HAProxy) only tells the NLB "the port is open." It cannot distinguish whether the node is actually a primary or a replica.
> Using HTTP on port 9000 (writes) and port 9001 (reads), HAProxy itself acts as the health check responder — returning 200 only when the node satisfies the role being checked (primary for writes, replica for reads), and 503 otherwise.
> This means the NLB routes write traffic exclusively to whichever node Patroni has elected as primary, and read traffic to the replica — automatically, without manual intervention.
> If Patroni promotes a replica or a failover occurs, the health check responses flip accordingly, and the NLB reroutes traffic within seconds.

---

## Phase 6 — PgBackRest (PostgreSQL Nodes)

### 6.1 Install

```bash
# On all 3 PostgreSQL nodes
# Install pgBackRest (apt — Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y pgbackrest
 
# Verify version (must be 2.47+ for zst compression + backup-standby fixes)
pgbackrest version
 
# Also install required utilities used by the backup script
sudo apt-get install -y jq netcat-openbsd
```

### 6.2 IAM and S3 Setup Run on your laptop with AWS-CLI configured

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

### 6.3 Save the keys printed by this command — you will not see the secret again
aws iam create-access-key --user-name pgbackrest-s3-user

### 6.4 Create and harden the S3 bucket
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

### 6.5 Create config, log, and spool directories
```bash
sudo mkdir -p /etc/pgbackrest \
             /var/log/pgbackrest \
             /var/spool/pgbackrest
 
# Transfer ownership to the postgres OS user
sudo chown -R postgres:postgres \
    /var/log/pgbackrest \
    /var/spool/pgbackrest
```

### 6.6 Generate SSH Keypair — postgres User on Both Nodes
#### Switch to postgres user
```bash
sudo -i -u postgres
 
# Create .ssh directory with correct permissions
mkdir -p ~/.ssh
chmod 700 ~/.ssh
 
# Generate Ed25519 keypair (no passphrase — required for non-interactive use)
ssh-keygen -t ed25519 -f ~/.ssh/pgbackrest_rsa -N "" -C "pgbackrest@$(hostname)"
 
# Exit postgres shell temporarily to copy keys
exit
```

### 6.7 Exchange Public Keys Between Nodes
#### Each node needs the other node's public key in its authorized_keys file. The file must contain keys from BOTH nodes so that either can SSH to either.
```bash
# ── On pg-node-1: copy its public key to pg-node-2 ──────────────────────
# First, view the public key on node-1
sudo -u postgres cat /var/lib/postgresql/.ssh/pgbackrest_rsa.pub
 
# On pg-node-2 — append node-1's key to authorized_keys
sudo -u postgres bash -c 'echo "PASTE_NODE1_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys'
sudo -u postgres chmod 600 ~/.ssh/authorized_keys
 
# ── On pg-node-2: copy its public key to pg-node-1 ──────────────────────
# First, view the public key on node-2
sudo -u postgres cat /var/lib/postgresql/.ssh/pgbackrest_rsa.pub
 
# On pg-node-1 — append node-2's key to authorized_keys
sudo -u postgres bash -c 'echo "PASTE_NODE2_PUBLIC_KEY_HERE" >> ~/.ssh/authorized_keys'
sudo -u postgres chmod 600 ~/.ssh/authorized_keys
```

### 6.8 Add Self-Loop Key (Each Node to Itself)
#### pgBackRest's backup-standby fallback path uses pg3-host=127.0.0.1 (loopback) as a last-resort standby. The postgres user must also be able to SSH to its own loopback address without a password. Run on EACH node independently:
```bash
# On EACH node — add its own public key to its own authorized_keys
sudo -u postgres bash -c 'cat ~/.ssh/pgbackrest_rsa.pub >> ~/.ssh/authorized_keys'
sudo -u postgres chmod 600 ~/.ssh/authorized_keys
 
# Verify authorized_keys contains all required keys (should have 2 entries per node)
sudo -u postgres cat ~/.ssh/authorized_keys | wc -l
# Expected: 2  (own key + partner key)
```

### 6.9 Configure SSH Client — Known Hosts & Identity File
#### Create or update ~/.ssh/config for the postgres user on BOTH nodes to pre-approve the host keys and specify the pgBackRest keypair:
```bash
# ── pg-node-1: /var/lib/postgresql/.ssh/config ───────────────────────────
sudo -u postgres tee /var/lib/postgresql/.ssh/config <<'EOF'
Host 172.31.37.150
    User postgres
    IdentityFile ~/.ssh/pgbackrest_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    BatchMode yes
 
Host 127.0.0.1
    User postgres
    IdentityFile ~/.ssh/pgbackrest_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    BatchMode yes
EOF
sudo -u postgres chmod 600 /var/lib/postgresql/.ssh/config
```

```bash
# ── pg-node-2: /var/lib/postgresql/.ssh/config ───────────────────────────
sudo -u postgres tee /var/lib/postgresql/.ssh/config <<'EOF'
Host 172.31.10.62
    User postgres
    IdentityFile ~/.ssh/pgbackrest_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    BatchMode yes
 
Host 127.0.0.1
    User postgres
    IdentityFile ~/.ssh/pgbackrest_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    BatchMode yes
EOF
sudo -u postgres chmod 600 /var/lib/postgresql/.ssh/config
```

### 6.10 Verify All Four SSH Paths
#### Run ALL four tests. Every test must return the hostname with zero prompts. Any failure must be resolved before proceeding.
```bash
# ── From pg-node-1 ───────────────────────────────────────────────────────
sudo -u postgres ssh 172.31.37.150 hostname        # must print: pg-node-2
sudo -u postgres ssh 127.0.0.1    hostname        # must print: pg-node-1
 
# ── From pg-node-2 ───────────────────────────────────────────────────────
sudo -u postgres ssh 172.31.10.62 hostname        # must print: pg-node-1
sudo -u postgres ssh 127.0.0.1    hostname        # must print: pg-node-2
 
# ── Quick pgBackRest-level SSH test (after config is in place) ───────────
# On node-1, as postgres:
sudo -u postgres pgbackrest --stanza=lamisplus --pg-host=172.31.37.150 \
    --pg-path=/data/patroni remote --type=db info 2>&1 | head -5
```

### 6.11 Patroni bootstrap.dcs Settings (patroni.yml)
#### Add or confirm the following under the postgresql.parameters block in /etc/patroni/patroni.yml on BOTH nodes:
#### ℹ  NOTE: Patroni writes these parameters to PostgreSQL's DCS (etcd). After updating patroni.yml, reload Patroni (sudo systemctl reload patroni) on both nodes — do NOT restart PostgreSQL directly.

```bash
# /etc/patroni/patroni.yml — postgresql parameters section
bootstrap:
  dcs:
    postgresql:
      parameters:
        wal_level: replica
        archive_mode: on
        archive_command: >-
          pgbackrest --stanza=lamisplus archive-push %p
        archive_timeout: 60
        max_wal_senders: 5
        wal_keep_size: 512
 
# IMPORTANT: archive_command uses the async wrapper automatically because
# archive-async=y is set in pgbackrest.conf. Do not add --no-archive-async.
```

### 6.12 Confirm PostgreSQL Archive Settings After Reload
```bash
# Check live GUC values (run as postgres or via psql)
sudo -u postgres psql -c "SHOW archive_mode;"
sudo -u postgres psql -c "SHOW archive_command;"
sudo -u postgres psql -c "SHOW wal_level;"
 
# Confirm archiving is actually working after stanza-create (Section 4)
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
# last_failed_operation should be NULL, archived_count should be growing
```

### 6.13 Node-1 Configuration (/etc/pgbackrest/pgbackrest.conf)
```bash
# Copy and adapt on each PostgreSQL node
sudo cp /path/to/repo/config/pgbackrest/pgbackrest.conf.example /etc/pgbackrest/pgbackrest.conf
# Edit all PLACEHOLDER_ values and the node-specific IP addresses
sudo nano /etc/pgbackrest/pgbackrest.conf

# Lock down file permissions — this file contains database passwords
sudo chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
sudo chmod 600 /etc/pgbackrest/pgbackrest.conf
```

### 6.14 Create the Stanza (Primary Node Only — One Time)
```bash
# Run ONCE on whichever node is currently the Patroni leader (primary)
# First confirm which node is leader:
patronictl -c /etc/patroni/patroni.yml list
 
# Then on the leader node:
sudo -u postgres pgbackrest --stanza=lamisplus stanza-create
 
# Expected output (last line):
# INFO: stanza-create command end: completed successfully
```

### 6.15 Check Stanza — Both Nodes
```bash
# Run on BOTH nodes
sudo -u postgres pgbackrest --stanza=lamisplus check
 
# Expected: INFO: check command end: completed successfully
# The check command verifies:
#   1. S3 connectivity and credentials
#   2. archive_command is correctly configured
#   3. A test WAL segment is pushed and confirmed in S3
 
# Also run info to confirm the stanza is registered
sudo -u postgres pgbackrest --stanza=lamisplus info
```

### 6.16 Take the First Full Backup
```bash
# Run from primary node — this seeds the S3 repository
# backup-standby=y means data files are read from the replica (node-2)
# but backup control commands still run on the primary
sudo -u postgres pgbackrest --stanza=lamisplus --type=full backup
 
# Monitor progress in real time
tail -f /var/log/pgbackrest/lamisplus-backup.log
 
# Confirm backup appears in repository
sudo -u postgres pgbackrest --stanza=lamisplus info
```

### 6.17 Automated Backup Script
```bash
sudo tee /usr/local/bin/run-pgbackrest-backup.sh <<'EOF'
#!/bin/bash
set -euo pipefail
 
STANZA="lamisplus"
PATRONI_CFG="/etc/patroni/patroni.yml"
HOSTNAME=$(hostname)
 
# ── 1. Get Patroni cluster status ────────────────────────────────────────
CLUSTER_STATUS=$(patronictl -c "$PATRONI_CFG" list --format json 2>/dev/null)
if [[ -z "$CLUSTER_STATUS" ]]; then
    echo "ERROR: Patroni unreachable or etcd down. Aborting."
    exit 1
fi
 
# ── 2. Identify partner node IP ──────────────────────────────────────────
if [[ "$HOSTNAME" == "pg-node-1" ]]; then
    OTHER_NODE="172.31.37.150"
else
    OTHER_NODE="172.31.10.62"
fi
 
# ── 3. Determine local role ───────────────────────────────────────────────
IS_LEADER=$(echo "$CLUSTER_STATUS" | jq -r \
    --arg h "$HOSTNAME" \
    '.[] | select(.Member == $h) | .Role' \
    | grep -ci "^leader$" || true)
 
# ── 4. Check partner reachability ────────────────────────────────────────
PARTNER_ALIVE=0
nc -z -w3 "$OTHER_NODE" 5432 && PARTNER_ALIVE=1 || true
 
# ── 5. Determine backup type by schedule ─────────────────────────────────
DOW=$(date +%u)   # 1=Mon … 7=Sun
DOM=$(date +%d)   # day of month 01–31
 
if [[ "$DOM" -eq 1 ]]; then
    BACKUP_TYPE="full"
elif [[ "$DOW" -eq 7 ]]; then
    BACKUP_TYPE="diff"
else
    BACKUP_TYPE="incr"
fi
# ── 6. Decision matrix ───────────────────────────────────────────────────
if [[ "$IS_LEADER" -eq 1 ]]; then
    if [[ "$PARTNER_ALIVE" -eq 1 ]]; then
        echo "INFO: Leader=$HOSTNAME, replica alive. Running $BACKUP_TYPE (standby offload)."
        sudo -u postgres pgbackrest --stanza="$STANZA" --type="$BACKUP_TYPE" backup
    else
        echo "WARN: Leader=$HOSTNAME, replica OFFLINE. Running local $BACKUP_TYPE."
        sudo -u postgres pgbackrest --stanza="$STANZA" --type="$BACKUP_TYPE" --no-backup-standby backup
    fi
else
    if [[ "$PARTNER_ALIVE" -eq 1 ]]; then
        echo "INFO: Replica=$HOSTNAME, leader alive. Deferring to leader."
        exit 0
    else
        echo "WARN: Replica=$HOSTNAME, leader ($OTHER_NODE) unreachable. Waiting 60s..."
        sleep 60
 
        PARTNER_ALIVE_RECHECK=0
        nc -z -w3 "$OTHER_NODE" 5432 && PARTNER_ALIVE_RECHECK=1 || true
 
        if [[ "$PARTNER_ALIVE_RECHECK" -eq 1 ]]; then
            echo "INFO: Leader came back online. Aborting emergency backup."
            exit 0
        fi
 
        RECHECK_STATUS=$(patronictl -c "$PATRONI_CFG" list --format json 2>/dev/null)
        IS_NOW_LEADER=0
        if [[ -n "$RECHECK_STATUS" ]]; then
            IS_NOW_LEADER=$(echo "$RECHECK_STATUS" | jq -r \
                --arg h "$HOSTNAME" \
                '.[] | select(.Member == $h) | .Role' \
                | grep -ci "^leader$" || true)
        fi
 
        if [[ "$IS_NOW_LEADER" -eq 1 ]]; then
            echo "INFO: Promoted to leader during failover. Running $BACKUP_TYPE (no standby)."
            sudo -u postgres pgbackrest --stanza="$STANZA" --type="$BACKUP_TYPE" --no-backup-standby backup
        else
            echo "WARN: Still replica, leader still gone. Running emergency $BACKUP_TYPE."
            sudo -u postgres pgbackrest --stanza="$STANZA" --type="$BACKUP_TYPE" --no-backup-standby backup
        fi
    fi
fi
EOF
 
sudo chmod +x /usr/local/bin/run-pgbackrest-backup.sh
sudo chown root:root /usr/local/bin/run-pgbackrest-backup.sh
```

### 6.18 Cron Configuration
#### The node-1 and node-2 crons are staggered by 10 minutes. When both are healthy, only the leader's cron will produce a backup — the replica's script exits early at the "Deferring to leader" check.
```bash
# ── pg-node-1 ─────────────────────────────────────────────────────────────
echo "0 1 * * * root bash /usr/local/bin/run-pgbackrest-backup.sh >> /var/log/pgbackrest/backup-cron.log 2>&1" \
    | sudo tee /etc/cron.d/pgbackrest-backup
 
# ── pg-node-2 ─────────────────────────────────────────────────────────────
echo "10 1 * * * root bash /usr/local/bin/run-pgbackrest-backup.sh >> /var/log/pgbackrest/backup-cron.log 2>&1" \
    | sudo tee /etc/cron.d/pgbackrest-backup
 
# ── Both nodes: create cron log file ─────────────────────────────────────
sudo touch /var/log/pgbackrest/backup-cron.log
sudo chown postgres:postgres /var/log/pgbackrest/backup-cron.log
 
# Verify cron file
cat /etc/cron.d/pgbackrest-backup
```


## 7 Restore Procedures
### 7.1 Full Restore to Latest Backup
#### ⚠  WARNING: Always stop Patroni on the target node before restoring. Restoring while Patroni is active will result in conflicts and data loss.
```bash
# ── Step 1: Stop Patroni and PostgreSQL on target node ───────────────────
sudo systemctl stop patroni
 
# ── Step 2: Clear the existing data directory ────────────────────────────
sudo -u postgres rm -rf /data/patroni/*
 
# ── Step 3: Run pgBackRest restore ──────────────────────────────────────
sudo -u postgres pgbackrest --stanza=lamisplus \
    --delta restore
 
# ── Step 4: Start Patroni ─────────────────────────────────────────────────
sudo systemctl start patroni
 
# ── Step 5: Confirm recovery completed ───────────────────────────────────
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Should return f (false) when node is promoted back to primary
```

### 7.2 Point-in-Time Recovery (PITR)
```bash
# Restore to a specific timestamp
sudo -u postgres pgbackrest --stanza=lamisplus \
    --delta \
    --type=time \
    "--target=2025-06-01 14:30:00" \
    --target-action=promote \
    restore
 
# Restore to a specific LSN
sudo -u postgres pgbackrest --stanza=lamisplus \
    --delta \
    --type=lsn \
    --target=0/10000000 \
    --target-action=promote \
    restore
 
# List available backups to choose a restore point
sudo -u postgres pgbackrest --stanza=lamisplus info
```

## 8 Ongoing Monitoring & Verification
### 8.1 Daily Health Checks
```bash
# Check stanza status and last backup timestamp
sudo -u postgres pgbackrest --stanza=lamisplus info
 
# Check WAL archiving is not stalled
sudo -u postgres psql -c "SELECT \
    archived_count,
    last_archived_wal,
    last_archived_time,
    failed_count,
    last_failed_wal,
    last_failed_time
FROM pg_stat_archiver;"
 
# Tail backup cron log
tail -50 /var/log/pgbackrest/backup-cron.log
 
# Tail pgBackRest main log
ls -lt /var/log/pgbackrest/ | head -5
tail -100 /var/log/pgbackrest/lamisplus-backup.log
```

### 8.2 Validate a Backup Without Restoring
```bash
# pgBackRest can verify checksums of all files in S3 against the manifest
# This catches S3 corruption without performing a full restore
sudo -u postgres pgbackrest --stanza=lamisplus verify
 
# To verify a specific backup set only (use label from pgbackrest info)
sudo -u postgres pgbackrest --stanza=lamisplus \
    --set=20250601-010000F verify
```

### 8.3 S3 Bucket Checks
```bash
# List S3 repository contents (requires AWS CLI configured on the node)
aws s3 ls s3://lamisplus-pg-backups/pgbackrest/ --recursive --human-readable \
    | grep -E "(backup|archive)" | head -20
 
# Total size of the repository
aws s3 ls s3://lamisplus-pg-backups/pgbackrest/ --recursive \
    | awk '{ sum += $3 } END { printf "Total: %.2f GB\n", sum/1073741824 }'
```