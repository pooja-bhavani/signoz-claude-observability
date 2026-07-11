# Architecture

Deep-dive documentation for the SigNoz observability lab. The README covers
day-to-day usage; this document covers every resource, the security model,
data flows, known failure modes, and a disaster-recovery runbook.

**Design intent:** this is a single-instance, single-tenant *lab*, optimized
for one-command reproducibility and teardown — not availability or
durability. Everything the instance runs is derived from files in this repo;
telemetry data is treated as disposable. Decisions below (single AZ, local
state, instance replacement on config change) follow from that.

---

## 1. Repository layout

| Path | Role |
|---|---|
| `terraform/versions.tf` | Terraform `>= 1.5.0`, AWS provider `~> 5.0`, HTTP provider `~> 3.4`, region wiring |
| `terraform/main.tf` | All resources: IP auto-detect, AMI lookup, security group, EC2 instance |
| `terraform/variables.tf` | 6 input variables (region, instance type, key pair, CIDR, disk, MCP port) |
| `terraform/outputs.tf` | 8 outputs (IDs, endpoints, ready-made SSH commands) |
| `terraform/user_data.sh.tpl` | First-boot bootstrap: Docker → foundryctl → cast |
| `terraform/.tflint.hcl` | tflint rulesets (terraform `recommended` preset + AWS plugin) |
| `casting.yaml` | SigNoz Foundry casting: docker/compose flavor, MCP server enabled |
| `Makefile` | `init` / `plan` / `apply` / `destroy` / `status` wrappers around `terraform -chdir` |
| `.github/workflows/ci.yml` | CI: `fmt -check`, `validate`, `tflint` on every push and PR |
| `.pre-commit-config.yaml` | Local mirror of CI plus hygiene hooks |
| `.gitignore` | Excludes state, lock file, tfvars, `*.pem` keys |

There are no modules and no remote backend — state is local (see §6).

---

## 2. Resource inventory

### 2.1 `data "http" "my_ip"` (conditional)

Created only when `var.allowed_cidr == null` (the default). Fetches
`https://checkip.amazonaws.com` **at plan time** from the machine running
Terraform and produces the operator's public IP. `local.allowed_cidr` becomes
`<that-ip>/32`, or the literal `var.allowed_cidr` when set.

Consequences:

- Every plan/apply from a different network produces a different CIDR and
  therefore an in-place security-group update.
- Plans fail if outbound HTTPS to checkip.amazonaws.com is blocked (see §5.1).
- CI systems must set `-var allowed_cidr=...` explicitly; otherwise the SG
  would admit the CI runner's IP, not yours.

### 2.2 `data "aws_ami" "ubuntu_2204"`

Resolves the **most recent** Canonical (`099720109477`) Ubuntu 22.04 amd64
HVM AMI at plan time. Not pinned: when Canonical publishes a new AMI, the
next plan shows the instance being **replaced** (AMI is immutable on an
instance). This is accepted for a lab; pin the AMI ID if replacement churn
becomes a problem.

### 2.3 `aws_security_group.signoz_lab`

- `name_prefix = "signoz-lab-"` with `create_before_destroy = true`, so SG
  replacements (e.g. description changes) don't deadlock on the name.
- **No VPC argument** → lands in the **default VPC** of `var.aws_region`.
- Ingress (all TCP, all restricted to `local.allowed_cidr` only):

| Rule key | Port | Purpose | Condition |
|---|---|---|---|
| `ssh` | 22 | SSH | always |
| `signoz_ui` | 8080 | SigNoz web UI | always |
| `otlp_grpc` | 4317 | OTLP gRPC ingest | always |
| `otlp_http` | 4318 | OTLP HTTP ingest | always |
| `mcp` | 8000 | SigNoz MCP server | only if `var.open_mcp_port = true` |

- Egress: all protocols, all destinations (`0.0.0.0/0`) — required for apt,
  get.docker.com, signoz.io, GitHub, and Docker Hub pulls during bootstrap.

### 2.4 `aws_instance.signoz_lab`

| Attribute | Value | Notes |
|---|---|---|
| AMI | latest Ubuntu 22.04 (see 2.2) | unpinned |
| Type | `var.instance_type`, default `t3.large` | 2 vCPU / 8 GiB — SigNoz minimum; **burstable** (see §5.6) |
| Key pair | `var.key_name`, default `My-key` | must already exist in the region; Terraform does not create it |
| Subnet | none specified | default VPC, default subnet, AZ chosen by AWS |
| Public IP | assigned by default-subnet setting | changes on stop/start (see §5.5) |
| Root volume | `var.root_volume_gb` (default 40) GiB gp3 | **ClickHouse data lives here**; no separate data volume, no snapshots |
| IAM instance profile | none | the instance has no AWS API access (deliberate — see §3) |
| `user_data` | rendered `user_data.sh.tpl` with `casting.yaml` inlined | |
| `user_data_replace_on_change` | `true` | any edit to the bootstrap template **or** `casting.yaml` **replaces the instance** — all telemetry data is lost by design (no-drift guarantee) |

### 2.5 What is *not* managed here

Default VPC/subnets/route tables/IGW, the EC2 key pair, DNS, TLS
certificates, and everything inside the instance after first boot
(containers are managed by Foundry/Compose, not Terraform).

---

## 3. Security model

**Perimeter.** A single security group is the entire perimeter. All five
ingress ports admit exactly one CIDR — the operator's `/32` (auto-detected)
or an explicit `var.allowed_cidr`. There is no ALB, WAF, VPN, or bastion.
Setting `allowed_cidr` to a broad range (or `0.0.0.0/0`) would expose an
**unauthenticated-by-default** SigNoz UI and open OTLP ingest to the
internet — don't.

**Transport.** Everything is plaintext HTTP/gRPC (`http://…:8080`,
`:4317/:4318`). Acceptable only because the network path is restricted to
one IP. Anyone on the operator's NAT/VPN egress shares that IP and can reach
the lab.

**SSH.** Key-pair auth only (Ubuntu AMI default: no passwords). The private
key (`My-key.pem`) stays outside the repo — `.gitignore` excludes `*.pem`.
Note the key sits one directory up in the working tree; never move it into
the repo.

**MCP server (port 8000).** Off the perimeter by default: `open_mcp_port`
defaults to `false`, and access is via SSH tunnel
(`ssh -N -L 8000:localhost:8000 …`), so MCP inherits SSH's authentication.
MCP clients additionally authenticate with a SigNoz API key minted in the UI
(Settings → API Keys). With `open_mcp_port = true`, port 8000 is exposed to
`allowed_cidr` — the API key becomes the only auth layer.

**Instance → AWS.** No IAM instance profile. A compromised instance holds no
AWS credentials; blast radius is the instance itself plus whatever can be
sent to it from its egress.

**Bootstrap supply chain (accepted lab risk).** First boot pipes two remote
scripts into a root shell: `https://get.docker.com` and
`https://signoz.io/foundry.sh` (both HTTPS, neither checksummed or
version-pinned). Container images are pulled unpinned from public
registries. Hardening would mean pinning and vendoring; not done for a lab.

**Secrets & state hygiene.** `.gitignore` excludes `*.tfstate*`, `*.tfvars*`
and `*.pem`. The state file contains the instance's IP and SG details but no
credentials (no provider secrets are written because auth comes from ambient
AWS credentials). SigNoz API keys live only inside SigNoz's ClickHouse
storage on the instance.

---

## 4. Data flows

### 4.1 Plan/apply time (operator machine)

1. Terraform reads ambient AWS credentials (env vars or `~/.aws`).
2. `data.http.my_ip` → HTTPS GET to checkip.amazonaws.com (only when
   `allowed_cidr` is null).
3. `data.aws_ami` → EC2 `DescribeImages`.
4. `templatefile()` inlines the full text of `casting.yaml` into
   `user_data.sh.tpl` via a quoted heredoc. The casting is therefore
   **baked in at plan time** — the instance never fetches config remotely,
   and config changes are visible in `terraform plan` as user_data diffs
   (which trigger replacement).

### 4.2 First boot (instance, ~5 minutes)

`user_data` runs once as root, `set -euxo pipefail`, everything tee'd to
`/var/log/signoz-lab-bootstrap.log`:

1. `apt-get update` → Ubuntu mirrors.
2. `curl get.docker.com | sh` → installs Docker; `ubuntu` user added to the
   `docker` group; dockerd enabled + started.
3. `curl signoz.io/foundry.sh | bash` in `/opt/signoz` → installs
   `foundryctl` (on PATH or `/opt/signoz/bin/foundryctl` — the script checks
   both).
4. Writes the inlined casting to `/opt/signoz/casting.yaml`.
5. `foundryctl cast -f casting.yaml --no-ledger` → renders and starts the
   SigNoz Docker Compose stack (ClickHouse, otel-collector, SigNoz UI,
   MCP server) — image pulls from public registries.

A failure at any step aborts the script (`set -e`); cloud-init does **not**
retry (see §5.3).

### 4.3 Runtime

```
 OTel SDKs / collectors ──:4317 gRPC / :4318 HTTP──▶ otel-collector
                                                          │ writes
                                                          ▼
 operator browser ──:8080──▶ SigNoz UI ◀──queries── ClickHouse (root EBS)
                                                          ▲
 MCP client ──ssh tunnel :8000──▶ MCP server ──queries────┘
```

All persistent data (traces, metrics, logs, dashboards, users, API keys) is
ClickHouse data in Docker volumes on the **root EBS volume**.

### 4.4 CI (GitHub Actions)

Every push and PR: three independent jobs — `terraform fmt -check`,
`terraform init -backend=false && validate`, and `tflint` (terraform
`recommended` preset + AWS ruleset). CI never touches AWS: no credentials in
the workflow, validate runs backend-less, nothing plans or applies.
`.pre-commit-config.yaml` runs the same three checks locally per commit.

---

## 5. Failure modes

### 5.1 Operator IP rotation → lockout ("the lab disappeared")

The most common failure. The SG admits one `/32`; if your ISP/VPN rotates
your egress IP, **everything** (UI, SSH, OTLP) times out. Recovery is §7.2.
Corollary: `terraform plan` from a new network shows an SG rule change even
when you changed nothing — that diff *is* the fix.

### 5.2 checkip.amazonaws.com unreachable → plan fails

With `allowed_cidr = null`, plans hard-fail if the lookup fails. Workaround:
pass `-var allowed_cidr=x.x.x.x/32`.

### 5.3 Bootstrap failure → instance up, SigNoz never comes up

Any failing step (Docker install, foundry.sh download, image pulls,
`foundryctl cast`) aborts the script and it never re-runs. Symptoms:
instance running, port 8080 dead past ~10 minutes. Diagnose via
`tail /var/log/signoz-lab-bootstrap.log` over SSH; recover per §7.3.
External dependencies that can break it: Ubuntu mirrors, get.docker.com,
signoz.io (installer *and* any behavior change in `foundry.sh`), container
registries.

### 5.4 Config change → intentional instance replacement → data loss

`user_data_replace_on_change = true` means editing `casting.yaml` or
`user_data.sh.tpl` replaces the instance; the unpinned AMI (§2.2) also
forces replacement when Canonical ships a new image. **Replacement destroys
the root volume** — all telemetry, dashboards, users, and API keys are lost.
This is the deliberate no-drift trade-off. Always read the plan: `# forces
replacement` on the instance means "root volume will be wiped." Snapshot
first if anything on the instance matters (§7.6).

### 5.5 Stop/start → public IP changes

No Elastic IP. A stop/start (manual, AWS maintenance, spot-like
interruption) assigns a new public IP: outputs and any SDK endpoints go
stale. `terraform refresh` (or `make status`) re-reads the new IP; re-point
senders. (Reboots keep the IP; only stop/start changes it.)

### 5.6 Resource exhaustion on a burstable single node

- **Disk:** ClickHouse fills the 40 GiB root volume under sustained ingest;
  ClickHouse then rejects writes or crash-loops, and the *OS itself* may
  wedge since it shares the volume. Detect: `df -h /`. Recover: §7.5.
- **CPU credits:** `t3.large` is burstable. Sustained ingest/query load
  drains credits and throttles the instance to baseline — UI slow, ingest
  lagging, SSH sluggish. Detect via `CPUCreditBalance` in CloudWatch. Fix:
  `-var instance_type=m7i.large` (non-burstable) and apply.
- **Memory:** 8 GiB is SigNoz's floor. OOM kills typically hit ClickHouse
  first (`dmesg | grep -i oom`, container restart counts).

### 5.7 Container/daemon failures after successful bootstrap

Compose restart policies (as cast by Foundry) handle crashed containers and
reboots. If containers don't come back after a reboot, check `systemctl
status docker` and `docker ps -a` — Terraform knows nothing about this
layer; recovery is docker-level (§7.4) or replacement (§7.3).

### 5.8 Terraform state loss or drift (local state, single machine)

State lives only at `terraform/terraform.tfstate` on the operator's machine
— gitignored, unbacked-up. Losing it orphans the SG + instance (next apply
would create duplicates). Recovery is import (§7.7). Similarly, deleting
resources in the AWS console behind Terraform's back is repaired by
`terraform apply` (refresh detects, plan recreates — with data loss).

### 5.9 Casting heredoc edge case

`user_data.sh.tpl` embeds `casting.yaml` in a `<<'CASTING'` heredoc. A line
consisting of exactly `CASTING` inside casting.yaml would truncate the file
silently. Obscure but real; keep that token out of the casting.

### 5.10 Region/account preconditions

Apply fails cleanly if: the key pair `My-key` doesn't exist in
`var.aws_region` (each region needs its own), the default VPC was deleted
(no subnet to land in), or vCPU quotas are exhausted. All surface as apply
errors, not silent misbehavior.

---

## 6. State & environments

- **Backend:** local, in `terraform/terraform.tfstate` (no `backend` block;
  `.terraform.lock.hcl` is gitignored too, so provider versions float within
  `~> 5.0` / `~> 3.4` per machine). Multi-machine or team use requires
  adding a remote backend (S3 + DynamoDB) — out of scope for the lab.
- **Workspaces:** none used; one lab per checkout.
- **Blast radius of `make destroy`:** the instance (with all data) and the
  SG. Nothing else in the account is touched.

---

## 7. Disaster-recovery runbook

Guiding principle: the lab is cattle. When in doubt, **rebuild** (§7.1) —
it's 5 minutes and the repo is the single source of truth. Only reach for
surgical fixes when you need the telemetry data on the instance.

### 7.1 Full rebuild (nuke and pave) — ~6 min

```bash
make destroy        # or: terraform -chdir=terraform destroy
make apply
make status         # repeat until "SigNoz UI: UP"
```

Post-rebuild: re-mint SigNoz API keys, re-point OTLP senders at the new IP,
recreate users/dashboards (nothing survives).

### 7.2 Locked out (IP rotated)

1. Confirm: `curl -s checkip.amazonaws.com` differs from
   `terraform -chdir=terraform output -raw allowed_cidr`.
2. `make apply` — the SG updates **in place** (no instance replacement, no
   data loss). This is safe to run from any network you want admitted.
3. No working Terraform machine? AWS Console → EC2 → Security Groups →
   `signoz-lab-*` → edit the five inbound rules to your new `/32`. Terraform
   will re-assert its own value next apply — from the new network that's the
   same value, so no fight.

### 7.3 Instance up, SigNoz down (bootstrap or stack failure)

```bash
ssh -i My-key.pem ubuntu@$(terraform -chdir=terraform output -raw public_ip)
tail -100 /var/log/signoz-lab-bootstrap.log   # did bootstrap finish?
docker ps -a                                   # what's running/crashed?
docker logs <failing-container> --tail 100
df -h / ; free -m ; dmesg | grep -i oom        # resource causes
```

- Bootstrap died mid-way (transient download failure): fastest fix is
  replacement — `terraform -chdir=terraform apply -replace=aws_instance.signoz_lab`.
- Bootstrap finished, one container unhealthy: `docker restart <name>`, or
  re-cast in place: `sudo /opt/signoz/bin/foundryctl cast -f /opt/signoz/casting.yaml --no-ledger`
  (idempotent; falls back to `foundryctl` on PATH).

### 7.4 Instance unreachable but running (SSH and UI both dead, IP unchanged)

1. EC2 console → instance → screenshot / serial console for kernel or
   disk-full wedge.
2. Check instance status checks; if `impaired`, stop/start it (new public
   IP — refresh outputs, §5.5).
3. Still wedged → treat as lost: §7.1, or snapshot the volume first (§7.6)
   if data matters.

### 7.5 Disk full (ClickHouse filled the root volume)

Quick space (destructive to telemetry): over SSH, stop the stack and prune —
`docker system prune -af` plus dropping old ClickHouse partitions. Proper
fix: grow the disk —

```bash
terraform -chdir=terraform apply -var root_volume_gb=80
# gp3 grows in place (root_block_device change ≠ replacement); then on the instance:
sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1
```

Verify with the plan output that only `root_block_device.volume_size`
changes in place before confirming.

### 7.6 Preserving data across a replacement

Before any apply that shows `# forces replacement`:

1. EC2 console (or CLI) → create a **snapshot** of the instance's root
   volume.
2. Apply. To recover data later: create a volume from the snapshot, attach
   to the new instance as `/dev/sdf`, mount, and copy
   `/var/lib/docker/volumes/*clickhouse*` content across (stack stopped).

This is the only durability mechanism; nothing is snapshotted automatically.

### 7.7 Terraform state lost

Resources still exist; re-adopt them instead of recreating:

```bash
cd terraform && terraform init
# find the real IDs:
aws ec2 describe-instances --filters "Name=tag:Name,Values=signoz-lab" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,SecurityGroups]'
terraform import aws_security_group.signoz_lab sg-XXXX
terraform import aws_instance.signoz_lab i-XXXX
terraform plan   # expect: no changes, or only the allowed_cidr /32 diff
```

If the plan wants to replace the instance after import (user_data drift),
either accept the rebuild or, to keep data, snapshot first (§7.6).

### 7.8 Key pair lost (`My-key.pem` gone)

SSH is unrecoverable without the key; the lab still works (UI/OTLP
unaffected), but tunnels and debugging are gone. Create a new key pair in
the region, then `terraform apply -var key_name=<new-key>` — **key_name
forces instance replacement**, so treat as §7.6/§7.1.

### 7.9 Region-level event

No cross-region story by design. Recover by rebuilding elsewhere:
`terraform apply -var aws_region=us-west-2 -var key_name=<key-in-that-region>`
(fresh state dir or `-replace` as needed; region change replaces
everything). Telemetry is lost unless a snapshot was copied cross-region
beforehand.

---

## 8. Known limitations (accepted)

Single instance, single AZ, no HA, no TLS, no auth in front of OTLP beyond
the SG, no automated backups, unpinned AMI/installers/images, local
Terraform state, burstable instance class. All are deliberate lab-scope
trade-offs; promoting this design to anything production-shaped means
revisiting every item on this list.
