# Keyed by principal name (the last ARN path segment) rather than the raw
# ARN, since access_entries keys just need to be unique strings and a name
# reads better than an ARN in `terraform plan` output.
locals {
  cluster_admin_access_entries = {
    for arn in var.cluster_admin_principal_arns :
    element(split("/", arn), length(split("/", arn)) - 1) => {
      principal_arn = arn

      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

# terraform-aws-modules/eks/aws v20.x — the version where access_entries
# replaced aws-auth ConfigMap juggling. v21.x renamed several inputs; taking
# that upgrade is deliberate future work, not incidental to this milestone.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint is still IAM-authenticated — it's what lets the AWS
  # owner run kubectl from a laptop without a bastion/VPN. Private access is
  # also on so in-VPC callers (nodes, add-ons) never depend on internet
  # egress to reach the API server.
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Access entries only, no aws-auth ConfigMap.
  authentication_mode = "API"

  # OIDC provider for the cluster — required for every IRSA role below and
  # in Milestone 5 (AWS Load Balancer Controller, EBS CSI).
  enable_irsa = true

  # The principal that creates the cluster is the HCP run role (bootstrap's
  # OIDC role), not a human — nobody logs in as it. Leaving the module's
  # default cluster-creator-admin behavior on would make that the only admin
  # identity, so it's turned off in favor of an explicit access entry below
  # for the AWS owner's own principal.
  enable_cluster_creator_admin_permissions = false

  access_entries = local.cluster_admin_access_entries

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types

      capacity_type = "ON_DEMAND"

      min_size     = var.node_group_min_size
      desired_size = var.node_group_desired_size
      max_size     = var.node_group_max_size

      disk_size = 20 # GiB, gp3 (module default volume type)
    }
  }
}
