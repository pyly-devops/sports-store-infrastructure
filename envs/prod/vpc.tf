# terraform-aws-modules/vpc/aws, not hand-rolled — the brief requires public
# modules, and this one already handles route tables, NAT wiring and subnet
# tagging correctly.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i + length(var.availability_zones))]

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = true
  # One NAT gateway (~$32/mo) shared across all 3 AZs, instead of one per AZ
  # (~$96/mo). Trade-off: if that AZ has an outage, private-subnet egress
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
