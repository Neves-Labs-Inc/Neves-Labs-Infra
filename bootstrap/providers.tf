# Runs with management-account credentials (no profile, so AWS_PROFILE works)
# and hops into the member account, so one login is enough.
provider "aws" {
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.state_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project   = "neves-labs"
      ManagedBy = "terraform"
    }
  }
}
