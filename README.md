# SigNoz Observability Lab — Infrastructure as Code

Reproducible one-command deployment of a self-hosted [SigNoz](https://signoz.io)
observability stack on AWS EC2, deployed with
[SigNoz Foundry](https://github.com/SigNoz/foundry) and its `casting.yaml`,
with the SigNoz MCP server enabled.

<img width="1468" height="884" alt="image" src="https://github.com/user-attachments/assets/781f366a-1546-43ac-bd44-955a35638c93" />

## Architecture

```
                      your machine (allowed_cidr only)
                        │
        ┌───────────────┼──────────────────┬──────────────┐
        │ :22 SSH       │ :8080 SigNoz UI  │ :4317 OTLP gRPC
        │               │                  │ :4318 OTLP HTTP
        ▼               ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│  AWS EC2 · t3.large · Ubuntu 22.04 · 40 GiB gp3             │
│  Security group: 22/8080/4317/4318 from your IP only        │
│                                                             │
│   user_data (first boot):                                   │
│     1. install Docker            (get.docker.com)           │
│     2. install foundryctl        (signoz.io/foundry.sh)     │
│     3. foundryctl cast -f casting.yaml                      │
│                                                             │
│   ┌── Docker Compose (cast from casting.yaml) ───────────┐  │
│   │                                                      │  │
│   │  otel-collector ──▶ ClickHouse ◀── SigNoz UI :8080   │  │
│   │   :4317 / :4318         ▲                            │  │
│   │                         │                            │  │
│   │  MCP server :8000 ──────┘   (SSH tunnel by default)  │  │
│   └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

Everything the instance runs is derived from two files in this repo:

| File | Role |
|---|---|
| `terraform/` | EC2 instance, security group, bootstrap `user_data` |
| `casting.yaml` | SigNoz Foundry casting — docker/compose mode, MCP enabled |

The casting file is baked into `user_data` at plan time
(`user_data_replace_on_change = true`), so editing `casting.yaml` and running
`make apply` recreates the instance with the new config — the lab can never
drift from git.

## Prerequisites

- Terraform >= 1.5
- AWS credentials configured (`aws configure` or env vars)
- An existing EC2 key pair (default name `My-key`; override with
  `-var key_name=...` or a `terraform.tfvars`)

## Usage

```bash
make plan      # preview
make apply     # create the lab (~5 min until SigNoz is up)
make status    # outputs + UI health check
make destroy   # tear everything down
```

After `make apply`, Terraform prints the UI URL, OTLP endpoints, and ready-made
SSH commands. First boot takes ~5 minutes; follow along with:

```bash
ssh -i My-key.pem ubuntu@<public_ip> 'tail -f /var/log/signoz-lab-bootstrap.log'
```

### CI and local checks

Every push and pull request runs CI (`.github/workflows/ci.yml`):
`terraform fmt -check`, `terraform validate`, and `tflint`.

Run the same checks locally on each commit via [pre-commit](https://pre-commit.com):

```bash
pre-commit install                       # one-time hook setup
tflint --init --chdir=terraform          # one-time ruleset download
```

## Network access

The security group admits **only your IP** (auto-detected via
`checkip.amazonaws.com` at plan time, or pin it with `-var allowed_cidr=x.x.x.x/32`):

| Port | Service |
|---|---|
| 22 | SSH |
| 8080 | SigNoz UI |
| 4317 | OTLP gRPC ingest |
| 4318 | OTLP HTTP ingest |

If your ISP rotates your IP, re-run `make apply` — the security group updates
in place.

## MCP server

The casting enables the SigNoz MCP server (port 8000). It is **not** exposed
publicly by default — tunnel to it:

```bash
ssh -i My-key.pem -N -L 8000:localhost:8000 ubuntu@<public_ip>
```

then point your MCP client at `http://localhost:8000/mcp` with a SigNoz API
key (SigNoz UI → Settings → API Keys). To expose it directly instead, apply
with `-var open_mcp_port=true`.

## Sending telemetry

Point any OTel SDK or collector at the lab:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<public_ip>:4318   # HTTP
# or grpc://<public_ip>:4317 for gRPC
```
