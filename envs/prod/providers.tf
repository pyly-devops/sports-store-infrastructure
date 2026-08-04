provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "cloudcart"
      ManagedBy   = "terraform"
      Environment = "prod"
    }
  }
}
