output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.signoz_lab.id
}

output "public_ip" {
  description = "Public IP of the lab instance."
  value       = aws_instance.signoz_lab.public_ip
}

output "signoz_ui" {
  description = "SigNoz UI URL."
  value       = "http://${aws_instance.signoz_lab.public_ip}:8080"
}

output "otlp_grpc_endpoint" {
  description = "OTLP gRPC ingest endpoint."
  value       = "${aws_instance.signoz_lab.public_ip}:4317"
}

output "otlp_http_endpoint" {
  description = "OTLP HTTP ingest endpoint."
  value       = "http://${aws_instance.signoz_lab.public_ip}:4318"
}

output "ssh_command" {
  description = "SSH into the lab."
  value       = "ssh -i My-key.pem ubuntu@${aws_instance.signoz_lab.public_ip}"
}

output "mcp_tunnel_command" {
  description = "SSH tunnel for the SigNoz MCP server (then use http://localhost:8000/mcp)."
  value       = "ssh -i My-key.pem -N -L 8000:localhost:8000 ubuntu@${aws_instance.signoz_lab.public_ip}"
}

output "allowed_cidr" {
  description = "CIDR the security group admits."
  value       = local.allowed_cidr
}
