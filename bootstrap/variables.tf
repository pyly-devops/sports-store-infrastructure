variable "aws_region" {
  description = "AWS region the bootstrap IAM resources are created in. IAM is global, but the provider still requires a region."
  type        = string
  default     = "us-east-1"
}

variable "hcp_organization" {
  description = "HCP Terraform organization name."
  type        = string
  default     = "pyly-devops"
}

variable "hcp_project" {
  description = "HCP Terraform project that owns the sports-store-prod workspace."
  type        = string
  default     = "Default Project"
}

variable "hcp_prod_workspace" {
  description = "HCP Terraform workspace name whose runs are trusted to assume the run role. Must match envs/prod's cloud{} workspace name exactly."
  type        = string
  default     = "sports-store-prod"
}
