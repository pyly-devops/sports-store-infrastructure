# Nothing below is sensitive — no credential is ever an output of this
# workspace. AWS keys never exist here at all (OIDC), and role/repo ARNs
# don't authenticate as anything by themselves.

output "cluster_name" {
  description = "For `aws eks update-kubeconfig` (Milestone 5)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region everything was created in."
  value       = var.aws_region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "cluster_oidc_provider_arn" {
  description = "For any future IRSA role."
  value       = module.eks.oidc_provider_arn
}

output "ebs_csi_role_arn" {
  description = "Already wired into the aws-ebs-csi-driver add-on; output for debugging only."
  value       = module.ebs_csi_irsa.iam_role_arn
}

output "lb_controller_role_arn" {
  description = "Milestone 5 passes this into the aws-load-balancer-controller chart's serviceAccount.annotations."
  value       = module.lb_controller_irsa.iam_role_arn
}

output "ecr_registry_url" {
  description = "Milestone 5's imageRegistry Helm value."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "GitHub repo name -> full ECR repository URL. Milestone 6 push targets."
  value       = { for k, v in aws_ecr_repository.app : k => v.repository_url }
}

output "github_actions_role_arns" {
  description = "GitHub repo name -> IAM role ARN. Milestone 6 workflows assume these via aws-actions/configure-aws-credentials, pure copy-paste into each repo's workflow file."
  value       = { for k, v in aws_iam_role.github_actions_push : k => v.arn }
}

data "aws_caller_identity" "current" {}
