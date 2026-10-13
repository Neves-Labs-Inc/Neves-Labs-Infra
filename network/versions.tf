terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend blocks can't interpolate, so the bucket name and account ID are literals.
  backend "s3" {
    bucket       = "neves-labs-tfstate-277396470866"
    key          = "network/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    assume_role = {
      role_arn = "arn:aws:iam::277396470866:role/OrganizationAccountAccessRole"
    }
  }
}
