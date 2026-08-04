output "run_role_arn" {
  description = "Paste into the sports-store-prod HCP workspace as env var TFC_AWS_RUN_ROLE_ARN."
  value       = aws_iam_role.run_role.arn
}

output "oidc_provider_arn" {
  description = "The app.terraform.io OIDC provider ARN. Not consumed anywhere else; kept for debugging trust-policy issues."
  value       = aws_iam_openid_connect_provider.hcp_terraform.arn
}
