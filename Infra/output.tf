output "load_balancer_dns" {
  value       = aws_lb.main.dns_name
  description = "Open this address in a browser to see your running frontend app."
}

output "ecr_backend_url" {
  value       = aws_ecr_repository.backend.repository_url
  description = "The target Amazon ECR registry string for tagging and building the API image."
}

output "ecr_frontend_url" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "The target Amazon ECR registry string for tagging and building the web static UI image."
}