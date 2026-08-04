terraform {
  required_version = "~> 1.9"

  required_providers {
    # Pinned to the 5.x line to match the vpc/eks module versions below (both
    # v5.x / v20.x target provider ~> 5.0). Provider 6.x pairs with vpc v6.x
    # and eks v21.x — an upgrade to take deliberately together, not one piece
    # at a time.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # VCS-driven workspace: HCP Terraform posts a speculative plan on every PR
  # and applies only on the AWS owner's manual confirmation. The working
  # directory (envs/prod) is set in the workspace settings in the HCP UI, not
  # here.
  cloud {
    organization = "pyly-devops"

    workspaces {
      name = "sports-store-prod"
    }
  }
}
