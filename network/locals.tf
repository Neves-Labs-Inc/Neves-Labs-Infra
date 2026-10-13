locals {
  # The Neves-Labs member account; the only place this root may run.
  account_id = "277396470866"
  region     = "us-east-1"

  vpc_cidr      = "10.10.0.0/16"
  postgres_port = 5432

  # Client app VPC ranges, held now so future peerings never collide with this VPC.
  reserved_cidrs = {
    tutorlink-prod   = "10.20.0.0/16"
    tn-cleaning-prod = "10.30.0.0/16"
  }

  # Keyed by AZ ID, not name: AZ names map to different zones per account.
  private_subnets = {
    use1-az1 = "10.10.0.0/24"
    use1-az2 = "10.10.1.0/24"
  }
}
