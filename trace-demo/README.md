# Trace Demo — Two-Service Flask App with OpenTelemetry

A minimal two-service Python app that generates distributed traces and logs, exported to a self-hosted SigNoz instance via OTLP/HTTP.

`checkout-service` calls `inventory-service` on every request — SigNoz shows the full trace waterfall, service map, RED metrics, and correlated logs with zero code changes.

## Architecture

```
┌────────────────────────────────────────────────────────┐
│  Your Machine                                          │
│                                                        │
│  checkout-service (:5001)                              │
│       │                                                │
│       │  GET /inventory/{item_id}                      │
│       ▼                                                │
│  inventory-service (:5002)                             │
│                                                        │
└────────────────┬───────────────────────────────────────┘
                 │ OTLP / HTTP :4318
                 ▼
┌────────────────────────────────────────────────────────┐
│  SigNoz (self-hosted on EC2)                           │
│  Traces → Traces Explorer                              │
│  Logs   → Logs Explorer                                │
│  APM    → Services tab (auto-derived RED metrics)      │
└────────────────────────────────────────────────────────┘
```

## Prerequisites

| Requirement | Version | Check |
|---|---|---|
| Python | >= 3.10 | `python3 --version` |
| pip | any recent | `pip --version` |
| SigNoz instance | running, OTLP port 4318 open | `curl -s -o /dev/null -w "%{http_code}" http://<SIGNOZ_IP>:4318/v1/traces` → 405 means alive |
| Ports 5001, 5002 | free on localhost | `lsof -i :5001,:5002` should return nothing |

## Setup

### 1. Clone and enter the directory

```bash
git clone https://github.com/pooja-bhavani/signoz-claude-observability.git
cd signoz-claude-observability/trace-demo
```

### 2. Install dependencies

```bash
pip install -r requirements.txt
```

This installs Flask, requests, and the OpenTelemetry distro + OTLP exporter.

### 3. Install auto-instrumentation packages

```bash
opentelemetry-bootstrap --action=install
```

This detects installed libraries (Flask, requests, urllib3) and installs the matching OTel instrumentation packages automatically.

### 4. Set your SigNoz endpoint

Edit `run.sh` and replace the IP with your SigNoz instance:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://<YOUR-SIGNOZ-IP>:4318"
```

### 5. Run both services

```bash
./run.sh
```

You should see:

```
Starting inventory-service on :5002...
Starting checkout-service on :5001...

Both services running!
  checkout-service: http://localhost:5001/checkout
  inventory-service: http://localhost:5002/inventory/SKU-001

SigNoz UI: http://<YOUR-SIGNOZ-IP>:8080
Press Ctrl+C to stop both...
```

## Generate traffic

```bash
# Single request
curl http://localhost:5001/checkout

# Burst of 50 requests
for i in $(seq 1 50); do curl -s http://localhost:5001/checkout; sleep 0.2; done
```

Each `/checkout` call generates a distributed trace with 3 spans:
1. `GET /checkout` (parent, checkout-service)
2. HTTP client span (checkout-service calling inventory)
3. `GET /inventory/{item_id}` (child, inventory-service)

## What to see in SigNoz

### Services tab
Both `checkout-service` and `inventory-service` appear automatically with rate, error %, and p99 latency (RED metrics) — derived from traces, no extra config.

### Traces Explorer
- Filter by `serviceName = checkout-service`
- Click any trace to see the waterfall: parent checkout span → HTTP client span → child inventory span
- Each span has auto-populated attributes: `http.method`, `http.route`, `http.status_code`, `net.peer.ip`

### Logs Explorer
- Filter by `resource.service.name = checkout-service`
- Logs include `trace_id` and `span_id` for correlation — click to jump to the corresponding trace

### Saved Views
1. Set up a query in Traces/Logs Explorer (e.g., `serviceName = checkout-service`)
2. Click **Save this view** (top-right)
3. Name it (e.g., "Checkout Traces")
4. Access it instantly from the Views dropdown next time

## Endpoints

| Service | Endpoint | Response |
|---|---|---|
| checkout-service | `GET /checkout` | `{"status": "confirmed", "item": "SKU-001", "stock": 25}` or `409 out_of_stock` |
| checkout-service | `GET /health` | `{"status": "ok"}` |
| inventory-service | `GET /inventory/<item_id>` | `{"item_id": "SKU-001", "available": true, "quantity": 25}` |
| inventory-service | `GET /health` | `{"status": "ok"}` |

Available SKUs: `SKU-001` (25), `SKU-042` (0 — always out of stock), `SKU-099` (12), `SKU-777` (3)

## Environment variables

All set in `run.sh`. Override any of these before running:

| Variable | Default | Purpose |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://13.235.136.2:4318` | SigNoz OTLP ingest endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | OTLP transport protocol |
| `OTEL_TRACES_EXPORTER` | `otlp` | Export traces to SigNoz |
| `OTEL_LOGS_EXPORTER` | `otlp` | Export logs to SigNoz |
| `OTEL_METRICS_EXPORTER` | `otlp` | Export runtime metrics to SigNoz |
| `OTEL_PYTHON_LOG_CORRELATION` | `true` | Inject trace_id/span_id into log records |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.name=<name>` | Service identity in SigNoz |

## Troubleshooting

**No traces in SigNoz after sending requests:**
- Verify endpoint is reachable: `curl -X POST http://<IP>:4318/v1/traces` → should return 400 or 200, not timeout
- Check security group allows your IP on port 4318
- Traces batch every 5 seconds by default — wait at least 10 seconds after requests

**Port already in use:**
```bash
lsof -i :5001 -t | xargs kill
lsof -i :5002 -t | xargs kill
```

**opentelemetry-instrument: command not found:**
```bash
pip install opentelemetry-distro
```

**Traces show but logs don't:**
- Verify `OTEL_LOGS_EXPORTER=otlp` is set
- Check SigNoz Logs Explorer with filter `resource.service.name = checkout-service`
