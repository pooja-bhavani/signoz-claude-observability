# SigNoz Observability Lab — Self-Hosted on AWS EC2

End-to-end observability setup: self-hosted SigNoz on EC2, monitoring Claude Code AI assistant telemetry (metrics + costs), plus a two-service Flask app generating distributed traces and logs.

<img width="1257" height="679" alt="Screenshot 2026-07-16 at 10 22 38 PM" src="https://github.com/user-attachments/assets/fbebb92a-ffd4-4a31-a88e-313e397fd86d" />

## What this project does

1. **Provisions an EC2 instance** with SigNoz installed via Foundry (one command)
2. **Collects Claude Code telemetry** — token usage, cost, cache efficiency, session count — over OTLP
3. **Imports a 26-panel dashboard** for Claude Code metrics
4. **Sets up alerts** — token burn spike → Slack notification
5. **Runs a trace demo** — two Flask microservices auto-instrumented with OpenTelemetry (traces + logs)

## Architecture

```
                      your machine (allowed_cidr only)
                        │
        ┌───────────────┼──────────────────┬───────────────────┐
        │ :22 SSH       │ :8080 SigNoz UI  │ OTLP / HTTP :4318 │
        ▼               ▼                  ▼                   │
┌──────────────────────────────────────────────────────────────┐
│  Security group: 22/8080/4318/8000 from your IP only         │
│                                                              │
│   user_data (first boot):                                    │
│     1. install Docker            (get.docker.com)            │
│     2. install foundryctl        (signoz.io/foundry.sh)      │
│     3. foundryctl cast -f casting.yaml                       │
│                                                              │
│   ┌── Docker Compose (cast from casting.yaml) ────────────┐  │
│   │                                                       │  │
│   │  otel-collector ──▶ ClickHouse ◀── SigNoz UI :8080    │  │
│   │   OTLP / HTTP :4318       ▲                           │  │
│   │                            │                          │  │
│   │  MCP server ───────────────┘                          │  │
│   │  <public_ip>:8000 · AI-queryable telemetry            │  │
│   └───────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## Prerequisites

### On your local machine

| Tool | Version | Install | Verify |
|---|---|---|---|
| Terraform | >= 1.5 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) | `terraform --version` |
| AWS CLI | v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | `aws --version` |
| AWS credentials | configured | `aws configure` (set region to `ap-south-1`) | `aws sts get-caller-identity` |
| EC2 key pair | exists in your region | AWS Console → EC2 → Key Pairs → Create | `aws ec2 describe-key-pairs --key-names My-key` |
| Python | >= 3.10 | [python.org](https://www.python.org/downloads/) (for trace-demo) | `python3 --version` |
| pip | any recent | comes with Python | `pip --version` |
| Claude Code | latest | `npm install -g @anthropic-ai/claude-code` | `claude --version` |
| curl | any | pre-installed on macOS/Linux | `curl --version` |
| make | any | pre-installed on macOS/Linux | `make --version` |

### AWS resources needed

| Resource | Details |
|---|---|
| EC2 key pair | named `My-key` (or override with `-var key_name=your-key`) |
| Default VPC | must exist in your region (AWS creates one by default) |
| Service quota | at least 1 running `t3.large` instance allowed |
| Budget | ~$2.20/day while running ($0.0832/hr instance + $0.003/hr disk + $0.005/hr IPv4) |

## Repository layout

```
.
├── Makefile                # make apply / destroy / status
├── casting.yaml            # SigNoz Foundry deployment config
├── terraform/
│   ├── main.tf             # EC2 instance + security group + auto-IP
│   ├── variables.tf        # input variables (region, instance type, key, etc.)
│   ├── outputs.tf          # public IP, SSH command, UI URL
│   ├── versions.tf         # provider versions
│   └── user_data.sh.tpl   # first-boot bootstrap script
├── trace-demo/
│   ├── app.py              # checkout-service (Flask, port 5001)
│   ├── inventory.py        # inventory-service (Flask, port 5002)
│   ├── requirements.txt    # Python dependencies
│   ├── run.sh              # starts both services with OTel instrumentation
│   └── README.md           # trace-demo specific docs
├── ARCHITECTURE.md         # deep-dive: security model, failure modes, DR runbook
└── .github/workflows/ci.yml  # CI: fmt, validate, tflint
```

## Step-by-step setup

### Step 1: Deploy SigNoz on EC2

```bash
git clone https://github.com/pooja-bhavani/signoz-claude-observability.git
cd signoz-claude-observability

make plan      # preview what Terraform will create
make apply     # creates EC2 + security group (~5 min for SigNoz to boot)
make status    # prints public IP + checks if SigNoz UI is up
```

Terraform auto-detects your current public IP and locks the security group to it. If you need to specify it manually:

```bash
terraform -chdir=terraform apply -var allowed_cidr="YOUR_IP/32"
```

Wait ~5 minutes for first boot. Monitor progress:

```bash
ssh -i My-key.pem ubuntu@<public_ip> 'tail -f /var/log/signoz-lab-bootstrap.log'
```

Once `make status` shows "SigNoz UI: UP", open `http://<public_ip>:8080` in your browser and create your admin account.

### Step 2: Wire Claude Code telemetry

Add these environment variables to `~/.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "http://<public_ip>:4318",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000"
  }
}
```

Replace `<public_ip>` with your EC2 public IP from `make status`.

**Open a NEW terminal** and start a Claude Code session. The env is read at startup — existing sessions won't emit telemetry.

Within 10 seconds, metrics appear in SigNoz:
- `claude_code.token.usage` — tokens by type (input, output, cacheRead, cacheCreation)
- `claude_code.cost.usage` — USD cost by model
- `claude_code.session.count` — sessions started
- `claude_code.active_time.total` — seconds of active work

### Step 3: Import the Claude Code dashboard

1. Go to SigNoz UI → **Dashboards** → **New Dashboard** → **Import JSON** (in the dropdown)
2. Paste the official dashboard JSON from [SigNoz/dashboards/claude-code](https://github.com/SigNoz/dashboards/tree/main/claude-code)
3. Save — you now have 26 panels: token usage, cost, cache efficiency, tool usage, cost leverage

### Step 4: Set up alerts (token burn → Slack)

**Create a Slack notification channel:**
1. SigNoz UI → **Settings** → **Notification Channels** → **New Channel**
2. Type: Slack Incoming Webhook
3. Name it (e.g., `slack-alerts`) — the name field is required before testing
4. Paste your Slack webhook URL → **Test** → **Save**

**Create an alert rule:**
1. **Alerts** → **New Alert** → **Metric Based**
2. Query: `claude_code.token.usage`, Within = **Increase**, Across = **Sum**
3. Condition: **above 100,000**, at least once, in last **5 minutes**
4. Notification channel: select your Slack channel
5. Alert name: "Claude Code token burn spike"
6. **Save**

**Important:** Make sure the threshold unit dropdown stays on the default (no unit) — not "min" or any time unit. Setting it to "min" converts your threshold to minutes and the alert will never fire.

### Step 5: Run the trace demo

```bash
cd trace-demo

# Install dependencies
pip install -r requirements.txt
opentelemetry-bootstrap --action=install

# Edit run.sh — set OTEL_EXPORTER_OTLP_ENDPOINT to your EC2 IP
# Then start both services:
./run.sh
```

Generate traffic:

```bash
# Single request (checkout calls inventory internally)
curl http://localhost:5001/checkout

# Burst of 50 requests
for i in $(seq 1 50); do curl -s http://localhost:5001/checkout; sleep 0.2; done
```

In SigNoz:
- **Services tab** — `checkout-service` and `inventory-service` appear with RED metrics
- **Traces Explorer** — distributed traces showing checkout → inventory span waterfall
- **Logs Explorer** — Flask logs with trace_id correlation

### Step 6: Create Saved Views

1. Go to **Traces Explorer** (or Logs Explorer)
2. Set up a query — e.g., filter `serviceName = checkout-service`
3. Click **Save this view** (top-right)
4. Name it (e.g., "Checkout Traces")
5. Access it from the **Views** dropdown anytime

## Network access

The security group admits **only your IP** (auto-detected at plan time):

| Port | Service |
|---|---|
| 22 | SSH |
| 8080 | SigNoz UI |
| 4318 | OTLP HTTP ingest |
| 8000 | MCP server (when `open_mcp_port=true`) |

If your ISP rotates your IP, re-run `make apply` — the security group updates in place (no data loss, no instance replacement).

## MCP server

The SigNoz MCP server is enabled on port 8000. Access via SSH tunnel (default):

```bash
ssh -i My-key.pem -N -L 8000:localhost:8000 ubuntu@<public_ip>
```

Then point your MCP client at `http://localhost:8000/mcp` with a SigNoz API key (Settings → API Keys).

To expose directly: `make apply` with `-var open_mcp_port=true`.

## Teardown

```bash
make destroy   # deletes EC2 instance + security group, all data lost
```

Running cost while active: **~$2.20/day**. The cheapest option is `make destroy` when you're done and `make apply` when you need it again (~5 min rebuild).

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `make status` shows "not responding" | Bootstrap still running | Wait 5 min, check `/var/log/signoz-lab-bootstrap.log` |
| SigNoz UI times out | Your IP changed | `make apply` (updates security group in place) |
| Claude Code metrics not appearing | Old terminal session | Open a NEW terminal, start a new `claude` session |
| OTLP silently drops data | Wrong IP or port blocked | Verify: `curl -X POST http://<ip>:4318/v1/traces` should return 400, not timeout |
| Alert says "all healthy" during spike | Unit dropdown set to "min" | Edit alert → set threshold unit to none (not minutes) |
| EC2 IP changed after stop/start | No Elastic IP assigned | Run `make status` to get new IP, update `OTEL_EXPORTER_OTLP_ENDPOINT` |
| Trace demo: port already in use | Old process still running | `lsof -i :5001 -t \| xargs kill` |
| `foundryctl: command not found` | PATH not set | `export PATH="$HOME/.local/bin:$PATH"` |

## CI

Every push and PR runs (`.github/workflows/ci.yml`):
- `terraform fmt -check`
- `terraform validate`
- `tflint` (terraform recommended preset + AWS plugin)

Local pre-commit hooks mirror the same checks:

```bash
pre-commit install
tflint --init --chdir=terraform
```
