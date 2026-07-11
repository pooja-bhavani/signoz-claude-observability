TF_DIR := terraform
TF     := terraform -chdir=$(TF_DIR)

.PHONY: init plan apply destroy status

init:
	$(TF) init

plan: init
	$(TF) plan

apply: init
	$(TF) apply
	@echo ""
	@echo "SigNoz is bootstrapping — first boot takes ~5 minutes."
	@echo "Track it with: make status"

destroy:
	$(TF) destroy

status:
	@$(TF) output 2>/dev/null || { echo "No state yet — run 'make apply' first."; exit 1; }
	@echo ""
	@ip=$$($(TF) output -raw public_ip 2>/dev/null); \
	if curl -sf -o /dev/null --max-time 5 "http://$$ip:8080"; then \
		echo "SigNoz UI: UP  -> http://$$ip:8080"; \
	else \
		echo "SigNoz UI: not responding yet (bootstrap takes ~5 min after apply)"; \
		echo "Inspect:   ssh ubuntu@$$ip 'tail -f /var/log/signoz-lab-bootstrap.log'"; \
	fi
