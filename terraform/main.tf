# Auto-detect the caller's public IP when allowed_cidr is not set.
data "http" "my_ip" {
  count = var.allowed_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  allowed_cidr = var.allowed_cidr != null ? var.allowed_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"

  ingress_rules = merge(
    {
      ssh       = { port = 22, description = "SSH" }
      signoz_ui = { port = 8080, description = "SigNoz UI" }
      otlp_grpc = { port = 4317, description = "OTLP gRPC ingest" }
      otlp_http = { port = 4318, description = "OTLP HTTP ingest" }
    },
    var.open_mcp_port ? {
      mcp = { port = 8000, description = "SigNoz MCP server" }
    } : {}
  )
}

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "signoz_lab" {
  name_prefix = "signoz-lab-"
  description = "SigNoz lab: SSH, UI, and OTLP ingest from allowed_cidr only"

  dynamic "ingress" {
    for_each = local.ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = [local.allowed_cidr]
    }
  }

  egress {
    description = "All outbound (image pulls, apt, foundry install)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "signoz-lab"
    Project = "signoz-observability-lab"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "signoz_lab" {
  ami                    = data.aws_ami.ubuntu_2204.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.signoz_lab.id]

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    casting_yaml = file("${path.module}/../casting.yaml")
  })

  # Replace the instance if the bootstrap script or casting changes,
  # so the lab never drifts from what is in git.
  user_data_replace_on_change = true

  tags = {
    Name    = "signoz-lab"
    Project = "signoz-observability-lab"
  }
}
