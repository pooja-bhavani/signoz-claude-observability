#!/usr/bin/env bash
# Bootstraps the SigNoz lab on first boot: Docker -> foundryctl -> cast.
# Progress is logged to /var/log/signoz-lab-bootstrap.log.
set -euxo pipefail
exec > >(tee /var/log/signoz-lab-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

# --- Docker (official convenience script) -----------------------------------
apt-get update -y
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable --now docker

# --- SigNoz Foundry ----------------------------------------------------------
install_dir=/opt/signoz
mkdir -p "$install_dir"
cd "$install_dir"

curl -fsSL https://signoz.io/foundry.sh | bash

# The installer places foundryctl either on PATH or in ./bin.
FOUNDRYCTL=$(command -v foundryctl || true)
if [ -z "$FOUNDRYCTL" ]; then
  FOUNDRYCTL="$install_dir/bin/foundryctl"
fi

# --- Casting (rendered from ../casting.yaml by Terraform) ---------------------
cat > "$install_dir/casting.yaml" <<'CASTING'
${casting_yaml}
CASTING

# --- Deploy -------------------------------------------------------------------
"$FOUNDRYCTL" cast -f "$install_dir/casting.yaml" --no-ledger

echo "SigNoz lab bootstrap complete."
