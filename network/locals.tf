locals {
  # The Neves-Labs member account; the only place this root may run.
  account_id = "277396470866"
  region     = "us-east-1"

  vpc_cidr      = "10.10.0.0/16"
  postgres_port = 5432

  # AWS's recommended network ACL ephemeral range; it covers every client OS's source ports.
  ephemeral_port_min = 1024
  ephemeral_port_max = 65535

  # Client app VPC ranges, held now so future peerings never collide with this VPC.
  reserved_cidrs = {
    tutorlink-prod   = "10.20.0.0/16"
    tn-cleaning-prod = "10.30.0.0/16"
  }

  # Derived from the client's reserved range (10.20.0.0/16 -> 210), not its position in
  # the map, so adding a client never renumbers another client's rules. The +10 keeps a
  # 10.0.x.x range off rule 0; AWS accepts 1-32766, and octet 255 gives 2560.
  network_acl_rule_numbers = {
    for client in keys(var.client_peerings) :
    client => tonumber(split(".", local.reserved_cidrs[client])[1]) * 10 + 10
  }

  # Keyed by AZ ID, not name: AZ names map to different zones per account.
  private_subnets = {
    use1-az1 = "10.10.0.0/24"
    use1-az2 = "10.10.1.0/24"
  }
}
