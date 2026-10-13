# Private-only network for neves-labs-pg: no internet gateway, NAT or peering here.
resource "aws_vpc" "shared" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "neves-labs-shared"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.shared.id
  availability_zone_id    = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "neves-labs-private-${each.key}"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Only the implicit local route; #4 adds the peering route here.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.shared.id

  tags = {
    Name = "neves-labs-private"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# No rule blocks: Terraform strips AWS's default allow-all rules from the VPC's default SG.
resource "aws_default_security_group" "locked" {
  vpc_id = aws_vpc.shared.id
}

# No egress rules: SGs are stateful, so replies to clients still flow, and Terraform
# strips AWS's default allow-all egress when it creates the group.
resource "aws_security_group" "postgres" {
  name        = "neves-labs-pg"
  description = "Postgres for peered client app VPCs"
  vpc_id      = aws_vpc.shared.id

  tags = {
    Name = "neves-labs-pg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = local.reserved_cidrs

  security_group_id = aws_security_group.postgres.id
  description       = "Postgres from ${each.key}"
  ip_protocol       = "tcp"
  from_port         = local.postgres_port
  to_port           = local.postgres_port
  cidr_ipv4         = each.value
}

resource "aws_db_subnet_group" "postgres" {
  name        = "neves-labs-pg"
  description = "Private subnets for neves-labs-pg"
  subnet_ids  = [for subnet in aws_subnet.private : subnet.id]

  lifecycle {
    prevent_destroy = true
  }
}
