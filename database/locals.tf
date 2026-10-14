locals {
  # The Neves-Labs member account; the only place this root may run.
  account_id = "277396470866"
  region     = "us-east-1"

  # Values from the applied network root (#2), all in VPC vpc-07716890a00dbcb5b.
  postgres_security_group_id = "sg-0ba246dae19e683c9"
  db_subnet_group_name       = "neves-labs-pg"
  availability_zone_id       = "use1-az1"

  admin_username = "neveslabs_admin"
  postgres_port  = 5432
}
