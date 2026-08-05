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

  # t3.large as of Milestone 8, up from t3.small. This is the only change in
  # the milestone that alters the AWS bill.
  #
  # WHY IT HAD TO CHANGE. Two t3.small give 2 GiB each; after kubelet and
  # system reservation and the existing DaemonSets, roughly 3 GiB is
  # schedulable across the whole cluster, and the application plus MongoDB
  # already claim most of it. Milestone 8 adds about 4-4.5 GiB of requests:
  # Prometheus ~2 GiB, Loki ~1 GiB, Grafana and Alertmanager ~256 MiB each,
  # kube-state-metrics ~128 MiB, and node-exporter plus Alloy on every node.
  #
  # It does not fit, and the failure mode is misleading: Prometheus sits
  # Pending on "Insufficient memory", which reads as a chart problem rather
  # than a capacity one. This was anticipated when Milestone 4 was written -
  # see the note on node_group_desired_size below.
  #
  # WHY 2 x t3.large AND NOT 4 x t3.medium. The price is identical
  # (2 x $0.0832 vs 4 x $0.0416 per hour) and both give 16 GiB raw, but each
  # node pays a fixed tax: kubelet reservation, the OS, and one replica each
  # of node-exporter, Alloy, aws-node and kube-proxy. Four nodes pay it four
  # times, two pay it twice - roughly 1.5 GiB more actually schedulable on the
  # two-node shape. Fewer nodes also means fewer DaemonSet pods to wait on at
  # demo time.
  #
  # COST: the cluster goes from ~$0.19/hr to ~$0.32/hr while it is up, plus
  # ~30 GiB of gp3 for the Prometheus, Loki and Alertmanager volumes (about
  # $2.40/month, under half a cent an hour). `terraform destroy` remains the
  # teardown path and removes all of it.
  #
  # CHANGING THIS REPLACES THE NODE GROUP: new nodes come up and the old ones
  # drain. MongoDB's PVC detaches and reattaches within the same AZ, since the
  # node group is pinned to one. It is not a cluster rebuild, but it should be
  # done in the same apply as a fresh cluster rather than as a second,
  # separate replacement.
  default = ["t3.large"]
}

variable "node_group_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 2
}

variable "node_group_desired_size" {
  description = "Desired node count. Stays at 2: Milestone 8's capacity need was met by widening the nodes to t3.large rather than adding more of them — see node_instance_types above for why that is cheaper per usable GiB."
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
