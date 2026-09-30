output "alb_dns_name" {
  description = "Open this URL in your browser to reach the web tier"
  value       = "http://${aws_lb.web_alb.dns_name}"
}

output "rds_endpoint" {
  description = "Private database endpoint (only reachable from the web servers)"
  value       = aws_db_instance.mysql_db.endpoint
}

output "runner_instance_id" {
  description = "Use with: aws ssm start-session --target <id>"
  value       = aws_instance.runner.id
}

output "nat_gateway_ip" {
  description = "Public IP used by the private web tier for outbound traffic"
  value       = aws_eip.nat.public_ip
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
