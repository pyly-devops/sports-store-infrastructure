locals {
  # /16 split into 16 /20s. 4096 addresses per subnet is far more than this
  # cluster needs, but VPC CIDR space is free and a /20 leaves room for the
  # VPC CNI to hand every pod a real IP without renumbering later.
  subnet_newbits = 4

  # Public subnets take block indices 0..7, private 8..15 — a *fixed*
  # reservation per tier, not one derived from the AZ count.
  #
  # This offset used to be `length(var.availability_zones)`, which packed the
  # private subnets immediately after the public ones. That reads tidier but
  # couples every private CIDR to the number of AZs: going 2 -> 3 AZs would
  # shift private subnet 0 from block 2 to block 3, renumbering all of them.
  # Terraform can't renumber a subnet in place, so it would destroy and
  # recreate them — and take the node group sitting in them along with it.
  # With a constant, adding an AZ only appends new blocks and leaves the
  # existing subnets untouched.
  private_subnet_offset = 8
}

# terraform-aws-modules/vpc/aws, not hand-rolled — the brief requires public
# modules, and this one already handles route tables, NAT wiring and subnet
# tagging correctly.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, local.subnet_newbits, i)]
  private_subnets = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, local.subnet_newbits, i + local.private_subnet_offset)]

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = true
  # One NAT gateway (~$32/mo) shared across both AZs, instead of one per AZ
  # (~$64/mo). Trade-off: if that AZ has an outage, private-subnet egress
  # dies cluster-wide, not just in one AZ. Wrong call for real production,
  # correct call for infra that's stood up for demos/verification and torn
  # back down — being able to say which is which is the point.
  single_nat_gateway = true

  # Without these tags the AWS Load Balancer Controller (Milestone 5) can't
  # auto-discover which subnets to place an ALB/NLB into, and it silently
  # fails rather than erroring clearly.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
