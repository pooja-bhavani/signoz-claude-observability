#!/bin/bash
# Run both services with OpenTelemetry auto-instrumentation
# Traces + Logs go to SigNoz on EC2

export OTEL_EXPORTER_OTLP_ENDPOINT="http://13.235.136.2:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_LOGS_EXPORTER="otlp"
export OTEL_TRACES_EXPORTER="otlp"
export OTEL_METRICS_EXPORTER="otlp"
export OTEL_PYTHON_LOG_CORRELATION="true"
export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED="true"

echo "Starting inventory-service on :5002..."
OTEL_RESOURCE_ATTRIBUTES="service.name=inventory-service" \
FLASK_APP=inventory \
  opentelemetry-instrument flask run --host 0.0.0.0 --port 5002 &
INVENTORY_PID=$!

sleep 2

echo "Starting checkout-service on :5001..."
OTEL_RESOURCE_ATTRIBUTES="service.name=checkout-service" \
FLASK_APP=app \
  opentelemetry-instrument flask run --host 0.0.0.0 --port 5001 &
CHECKOUT_PID=$!

sleep 2
echo ""
echo "Both services running!"
echo "  checkout-service: http://localhost:5001/checkout"
echo "  inventory-service: http://localhost:5002/inventory/SKU-001"
echo ""
echo "SigNoz UI: http://13.235.136.2:8080"
echo "Press Ctrl+C to stop both..."

trap "kill $INVENTORY_PID $CHECKOUT_PID 2>/dev/null; exit" INT TERM
wait
