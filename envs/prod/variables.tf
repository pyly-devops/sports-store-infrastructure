variable "aws_region" {
  description = "AWS region for every resource in this workspace."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "sports-store"
}

variable "kubernetes_version" {
  description = "EKS control plane version. Matches the minikube version Milestone 2/3 were verified against."
  type        = string
  default     = "1.32"
}

# --- VPC ---------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs for the VPC's public/private subnets. EKS requires the control-plane subnets to span at least 2 AZs, so 2 is the floor here even though the node group (below) is pinned to a single AZ to keep this a true single-AZ cost profile."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  # The lower bound is EKS's own rule. The upper bound is vpc.tf's fixed
  # block reservation: public takes CIDR blocks 0..7 and private 8..15, so a
  # 9th AZ would hand the 9th public subnet the same block as the 1st
  # private one. Caught here as a clear message at plan time rather than as
  # an overlapping-CIDR error from the AWS API mid-apply.
  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 8
    error_message = "availability_zones must contain between 2 and 8 AZs: EKS requires at least 2, and vpc.tf reserves 8 CIDR blocks per subnet tier."
  }
}

# --- EKS cluster access --------------------------------------------------

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Defaults wide open; tighten to the AWS owner's own IP/CIDR once known — the endpoint is still IAM-authenticated either way, so this is defense in depth, not the only gate."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs (users/roles) granted AmazonEKSClusterAdminPolicy via an EKS access entry. Must include the AWS owner's own principal — the cluster is created by the HCP run role, an identity nobody logs in as, so this is the only way a human gets kubectl access. Set via an HCP workspace variable, not defaulted here."
  type        = list(string)
  default     = []
}

# --- Node group ----------------------------------------------------------

variable "node_instance_types" {
  description = "Instance types for the default managed node group."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_group_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 2
}

variable "node_group_desired_size" {
  description = "Desired node count. Two t3.small covers Milestone 4/5 (7 app pods + MongoDB). Milestone 8's kube-prometheus-stack + Loki will need this raised (or the instance type bumped to t3.large) — see docs/status.md."
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 6
}

# --- ECR / GitHub Actions --------------------------------------------------

variable "github_org" {
  description = "GitHub org that owns every app repo."
  type        = string
  default     = "pyly-devops"
}

variable "app_components" {
  description = "Single source of truth for the 7 app components: GitHub repo name (in github_org) -> ECR repository name suffix (under sports-store/). Both ecr.tf and github-oidc.tf iterate this same map so they can never drift out of sync with each other."
  type        = map(string)
  default = {
    "sports-store-auth-service"    = "auth-service"
    "sports-store-catalog-service" = "catalog-service"
    "sports-store-cart-service"    = "cart-service"
    "sports-store-order-service"   = "order-service"
    "sports-store-payment-service" = "payment-service"
    "sports-store-gateway"         = "gateway"
    "sports-store-frontend"        = "frontend"
  }
}
