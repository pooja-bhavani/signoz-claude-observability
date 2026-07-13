# Architecture

Deep-dive documentation for the SigNoz observability lab. The README covers
day-to-day usage; this document covers every resource, the security model,
data flows, known failure modes, a disaster-recovery runbook, monthly cost
estimation, and a CIS-mapped security-hardening checklist.

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

## 8. Cost estimation

On-demand pricing, **us-east-1**, 730 hours/month, as of July 2026. Other
regions differ by ±5–25%; re-check at
[aws.amazon.com/ec2/pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
or [instances.vantage.sh](https://instances.vantage.sh/aws/ec2/t3.large)
before budgeting.

### 8.1 Always-on baseline (default variables)

| Line item | Unit price | Monthly |
|---|---|---:|
| EC2 `t3.large` (2 vCPU, 8 GiB), on-demand | $0.0832/hr | $60.74 |
| EBS root volume, gp3, 40 GiB | $0.08/GiB-mo | $3.20 |
| Public IPv4 address (while running) | $0.005/hr | $3.65 |
| Data transfer **in** (OTLP ingest) | free | $0.00 |
| Data transfer **out**, first 100 GB/mo | free tier | $0.00 |
| **Baseline total** | | **≈ $67.59/mo** (~$2.22/day, ~$0.093/hr) |

The security group, AMI lookup, and default-VPC networking are free. gp3's
included 3,000 IOPS / 125 MB/s baseline is not exceeded by a lab workload,
so no provisioned-performance charges apply.

### 8.2 Variable and situational costs

| Item | Price | When it bites |
|---|---|---|
| t3 surplus CPU credits (`unlimited` mode default) | $0.05 per vCPU-hour above baseline | Sustained load above the ~30%/vCPU baseline; worst case (both vCPUs pegged 24/7) adds ≈ $51/mo — at which point a fixed-rate instance is cheaper (see 8.3) |
| Data transfer out beyond 100 GB/mo | $0.09/GB | Heavy UI/API querying from outside AWS; rare for one user |
| EBS snapshots (DR runbook §7.6) | $0.05/GB-mo (standard tier) | Each retained snapshot of the 40 GiB volume: ≤ $2.00/mo (first is full, rest incremental) |
| Bigger disk (§7.5) | $0.08/GiB-mo | 80 GiB → $6.40/mo instead of $3.20 |
| Stopped (not destroyed) instance | EBS only | Stopping halts instance + IPv4 charges but keeps paying for the volume: ≈ $3.20/mo idle |

### 8.3 Cost levers

| Change | New compute cost | Trade-off |
|---|---:|---|
| `make destroy` when not in use (the intended pattern) | $0 | 5-minute rebuild, telemetry lost — this is the design (§7.1); 8 hrs/day × 22 days ≈ **$16/mo** total |
| `-var instance_type=t3a.large` | $54.90/mo | AMD, ~10% cheaper, same credit model |
| `-var instance_type=m7i.large` | $73.58/mo | No burst credits — predictable under sustained ingest (§5.6) |
| 1-yr Compute Savings Plan | ≈ –30–40% | Only sensible if the lab becomes permanent, which contradicts its design |
| Spot | ≈ –60–70% | Interruption destroys the lab mid-session; poor fit even for a lab you're actively using |

**Rule of thumb:** left running 24/7 the lab costs about **$68/month**; used
as designed (apply for a session, destroy after) it costs **a few dollars a
month**. The single most effective cost control in this repo is
`make destroy`.

---

## 9. Security-hardening checklist (CIS-mapped)

Current posture vs. hardened posture, mapped to CIS benchmark controls.
Benchmarks referenced: **CIS AWS Foundations Benchmark v3.0**, **CIS Ubuntu
Linux 22.04 LTS Benchmark v2.0**, **CIS Docker Benchmark v1.6** — control
numbers shift between benchmark revisions, so treat the numbers as pointers
and the control titles as authoritative. ✅ = already satisfied by this repo,
⚠️ = gap (acceptable for the lab, listed with the concrete fix).

### 9.1 AWS account & network layer (CIS AWS Foundations v3.0)

| # | Item | CIS control | Status |
|---|---|---|---|
| 1 | No ingress from `0.0.0.0/0` to admin ports — SG admits a single `/32` on 22/8080/4317/4318(/8000) | §5.2 / §5.3 *(no ingress from 0.0.0.0/0 or ::/0 to remote server administration ports)* | ✅ enforced in `main.tf`; degraded only if the operator passes a broad `allowed_cidr` — consider a `validation` block rejecting prefixes shorter than `/24` |
| 2 | Require IMDSv2 on the instance | §5.6 *(ensure EC2 Metadata Service only allows IMDSv2)* | ⚠️ `main.tf` sets no `metadata_options`. Low risk here (no IAM role → no credentials to steal), but the fix is 4 lines: `metadata_options { http_tokens = "required" http_put_response_hop_limit = 1 }` |
| 3 | Encrypt the EBS root volume at rest | §2.2.1 *(ensure EBS volume encryption is enabled)* | ⚠️ add `encrypted = true` to `root_block_device` (or enable account-level EBS encryption-by-default); forces instance replacement once |
| 4 | No IAM instance profile / least privilege | §1.x IAM family | ✅ deliberately none (§3) — an instance compromise yields zero AWS API access |
| 5 | No hardcoded/long-lived credentials in code or state | §1.4 *(no root access keys)*, secure-credential hygiene family | ✅ provider uses ambient credentials; state contains no secrets; `.gitignore` blocks `*.tfvars`/`*.pem` |
| 6 | CloudTrail enabled in all regions | §3.1 | ⚠️ account-level, outside this repo — verify once per account |
| 7 | VPC Flow Logs on the default VPC | §3.7 *(VPC flow logging enabled in all VPCs)* | ⚠️ not managed here; add an `aws_flow_log` + CloudWatch log group (~$1–3/mo) if you need network forensics |
| 8 | Default security group of the VPC restricts all traffic | §5.4 | ⚠️ account-level; the lab uses its own SG, but the default SG should still be closed |
| 9 | Billing/usage alarms & metric filters | §4.x monitoring family | ⚠️ account-level; a $20 budget alert also catches a forgotten lab (§8) |
| 10 | Restrict egress to what bootstrap needs | (beyond CIS baseline) | ⚠️ egress is `0.0.0.0/0`; could be narrowed to 443/80 + DNS — diminishing returns for a lab |

### 9.2 Instance / OS layer (CIS Ubuntu 22.04 LTS v2.0)

| # | Item | CIS control | Status |
|---|---|---|---|
| 11 | SSH: key-only auth, no passwords | §5.1.x SSH server family *(disable PasswordAuthentication)* | ✅ Ubuntu AMI default |
| 12 | SSH: `PermitRootLogin no`, limit to `AllowUsers ubuntu`, `MaxAuthTries 4` | §5.1.x SSH server family | ⚠️ AMI defaults are close but not asserted; add an sshd drop-in to `user_data.sh.tpl` |
| 13 | Host firewall (ufw) as second layer behind the SG | §4.x host firewall family | ⚠️ not configured. **Caution:** Docker bypasses ufw INPUT rules for published ports by design — if added, use it for SSH rate-limiting, not as the container perimeter |
| 14 | Unattended security updates | §1.x *(ensure updates, patches, and additional security software are installed)* | ⚠️ `unattended-upgrades` is present on Ubuntu but not asserted; one `dpkg-reconfigure` line in user_data. Note the instance is replaced (fresh AMI) on every config change anyway (§5.4), which caps patch staleness |
| 15 | auditd / process accounting | §6.x logging & auditing family | ⚠️ skipped — meaningful only if you'd actually review the logs; the lab's forensic story is "destroy and rebuild" |
| 16 | Time synchronization | §2.x *(ensure time synchronization is in use)* | ✅ systemd-timesyncd on the AMI; correct timestamps matter for an observability stack |

### 9.3 Docker & workload layer (CIS Docker v1.6)

| # | Item | CIS control | Status |
|---|---|---|---|
| 17 | Only trusted users control the Docker daemon | §1.x host configuration *(ensure only trusted users are allowed to control Docker daemon)* | ⚠️ `usermod -aG docker ubuntu` makes `ubuntu` root-equivalent. Accepted for a single-operator lab; the alternative is `sudo docker` everywhere |
| 18 | Docker daemon not exposed on TCP | §2.x daemon configuration | ✅ default unix socket only; no `-H tcp://` anywhere |
| 19 | Pin images by digest / verify content trust | §4.x container images *(content trust, trusted base images)* | ⚠️ Foundry pulls whatever tags the casting resolves to; pinning lives upstream in SigNoz Foundry, not this repo |
| 20 | Container resource limits (memory/CPU) | §5.x runtime | ⚠️ compose file is generated by `foundryctl`; unbounded ClickHouse memory is the practical risk (§5.6) |
| 21 | Verify piped installers (get.docker.com, foundry.sh) | supply-chain hygiene (outside CIS) | ⚠️ both piped to root shell over HTTPS, unpinned (§3); hardening = vendor the scripts into the repo at a reviewed commit and checksum them |

### 9.4 Application layer (SigNoz — outside CIS scope)

| # | Item | Status |
|---|---|---|
| 22 | Strong admin password set on first UI login | ⚠️ operator discipline; the UI is IP-restricted but unauthenticated ingest/queries within `allowed_cidr` are possible until the account exists |
| 23 | MCP server reached only via SSH tunnel (`open_mcp_port=false`) | ✅ default; flipping the flag makes the API key the sole auth layer (§3) |
| 24 | Rotate/scope SigNoz API keys; treat them as secrets | ⚠️ keys live in ClickHouse on the instance and die with it (§5.4) — rotation is largely enforced by the rebuild cycle |
| 25 | TLS in front of UI/OTLP (reverse proxy + ACM/Let's Encrypt) | ⚠️ everything is plaintext (§3); acceptable only behind the `/32`. First step if this ever outlives "lab" status |

**Priority order if hardening beyond lab scope:** #2 IMDSv2 and #3 EBS
encryption (cheap, in-repo, no operational cost) → #22 admin password +
#25 TLS (biggest real-world exposure) → #21 vendored installers (supply
chain) → the account-level items (#6–#9) once, per account.

---

## 10. Known limitations (accepted)

Single instance, single AZ, no HA, no TLS, no auth in front of OTLP beyond
the SG, no automated backups, unpinned AMI/installers/images, local
Terraform state, burstable instance class. All are deliberate lab-scope
trade-offs; promoting this design to anything production-shaped means
revisiting every item on this list.
