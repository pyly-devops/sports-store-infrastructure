terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # CLI-driven workspace: state is remote and locked, but `terraform apply`
  # runs on the AWS owner's laptop with their own credentials, not via OIDC.
  # It has to work this way — envs/prod authenticates as the role this module
  # creates, so this module can't authenticate as that role itself.
  cloud {
    organization = "pyly-devops"

    workspaces {
      name = "sports-store-bootstrap"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "cloudcart"
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}
