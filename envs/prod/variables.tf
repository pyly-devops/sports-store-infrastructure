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
  description = "IAM principal ARNs (users/roles) granted AmazonEKSClusterAdminPolicy via an EKS access entry. Must include the AWS owner's own principal — the cluster is created by the HCP run role, an identity nobody logs in as, so this is the only way a human gets kubectl access. Set via an HCP workspace variable."
  type        = list(string)

  # DELIBERATELY NO DEFAULT.
  #
  # eks.tf sets enable_cluster_creator_admin_permissions = false, and the
  # creating principal is the HCP run role — an identity nobody logs in as. So
  # this list is the ONLY way a human ever gets kubectl access to the cluster.
  #
  # This used to default to [], with the hazard written up in the description
  # above. A description is not a control: it is read by people who already
  # know and skipped by everyone else. With a default, forgetting it was a
  # SILENT SUCCESS — ~92 resources apply cleanly, billing starts, and the
  # failure only surfaces when someone runs kubectl against a cluster they
  # cannot administer. The only fix at that point is another apply.
  #
  # Required, it fails during variable evaluation instead, before a single
  # provider call. That costs nothing and cannot be forgotten.

  validation {
    condition     = length(var.cluster_admin_principal_arns) > 0
    error_message = "At least one admin principal is required, or the cluster comes up with no human administrator and only another apply can fix it. Set cluster_admin_principal_arns as an HCP workspace variable."
  }

  # The failure mode that is worse than forgetting: a malformed or typo'd ARN.
  # An EKS access entry accepts one without complaint and grants exactly
  # nobody, so the cluster looks configured and is not. Catch it here.
  validation {
    condition = alltrue([
      for arn in var.cluster_admin_principal_arns :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/", arn))
    ])
    error_message = "Each entry must be an IAM user or role ARN, e.g. arn:aws:iam::123456789012:role/Admin."
  }
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
  default     = 5
}

variable "node_group_desired_size" {
  description = "Desired node count. Two t3.small covered Milestone 4/5 (7 app pods + MongoDB) at ~99% memory requests already committed — measured directly (kubectl describe node) during Milestone 7, not assumed, when Argo CD (~950Mi) and External Secrets Operator (~200Mi) needed to schedule on top with zero headroom left. Raised to 3 rather than bumping the instance type: keeps the per-node cost profile, adds a full node's worth of budget (~1.9 vCPU/1.47Gi allocatable). Raised again to 4 for Milestone 8: kube-prometheus-stack + Loki need ~1560Mi and 3 nodes measured only 452Mi free even after reclaiming the ebs-csi-controller's second replica — see docs/plans/stage8-plan-observability.md §1. Raised again to 5 during the M8 verification pass (2026-08-07): the corrected 1714Mi model (see the same §1 update) still didn't account for fragmentation — 4 nodes had 990Mi of AGGREGATE free memory but no single node had more than 385Mi, and Prometheus's own 700Mi request needs 700Mi contiguous on one node. Measured live (`kubectl describe node`) before changing, not assumed: the best of the 4 nodes was still 315Mi short. A 5th node adds a full 1437Mi of contiguous free capacity, which a same-size trim to any existing workload's request cannot, since Kubernetes does not repack already-running pods across nodes."
  type        = number
  default     = 5
}

variable "node_group_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 6
}

# --- CloudFront (Milestone 9) ----------------------------------------------

variable "enable_cloudfront" {
  description = "Create the S3 + CloudFront static origin. MUST stay false until the cluster exists and the Load Balancer Controller has provisioned the ALB, because cloudfront.tf looks that ALB up with a data source rather than creating it — Terraform does not own it. Flipping this is the second phase of a deliberately two-phase apply; see cloudfront.tf."
  type        = bool

  # Defaults to false so that `terraform apply` from an empty account still
  # works exactly as Milestone 4 proved. With the flag off, every resource in
  # cloudfront.tf has count = 0 and the aws_lb data source is never
  # evaluated — so a from-zero apply cannot fail on a load balancer that does
  # not exist yet.
  default = false
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
