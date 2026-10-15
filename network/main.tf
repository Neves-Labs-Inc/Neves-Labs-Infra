# Private-only network for neves-labs-pg: no internet gateway or NAT. The only way in
# is a client peering from var.client_peerings, accepted below.
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

# The implicit local route plus one route per client peering (aws_route.client).
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

# Network ACLs are stateless: Postgres replies leave from 5432 to the client's
# ephemeral source port, so egress must allow 1024-65535 back to each app subnet.
# Anything not listed hits the implicit deny.
resource "aws_default_network_acl" "private" {
  default_network_acl_id = aws_vpc.shared.default_network_acl_id
  subnet_ids             = [for subnet in aws_subnet.private : subnet.id]

  dynamic "ingress" {
    for_each = var.client_peerings

    content {
      rule_no    = local.network_acl_rule_numbers[ingress.key]
      action     = "allow"
      protocol   = "tcp"
      cidr_block = ingress.value.app_subnet_cidr
      from_port  = local.postgres_port
      to_port    = local.postgres_port
    }
  }

  dynamic "egress" {
    for_each = var.client_peerings

    content {
      rule_no    = local.network_acl_rule_numbers[egress.key]
      action     = "allow"
      protocol   = "tcp"
      cidr_block = egress.value.app_subnet_cidr
      from_port  = local.ephemeral_port_min
      to_port    = local.ephemeral_port_max
    }
  }

  tags = {
    Name = "neves-labs-private"
  }

  lifecycle {
    precondition {
      condition     = length(distinct(values(local.network_acl_rule_numbers))) == length(local.network_acl_rule_numbers)
      error_message = "Network ACL rule numbers collide: every reserved range must be a /16 with its own second octet."
    }
  }
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

# Only the client's app subnet, not its whole reserved range.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.client_peerings

  security_group_id = aws_security_group.postgres.id
  description       = "Postgres from the ${each.key} app subnet"
  ip_protocol       = "tcp"
  from_port         = local.postgres_port
  to_port           = local.postgres_port
  cidr_ipv4         = each.value.app_subnet_cidr
}

# Read before accepting, so a mistyped or hostile pcx ID (the shared VPC's account is
# public in this repo) fails the plan instead of routing a client range to a stranger.
data "aws_vpc_peering_connection" "client" {
  for_each = var.client_peerings

  id = each.value.peering_connection_id
}

resource "aws_vpc_peering_connection_accepter" "client" {
  for_each = var.client_peerings

  vpc_peering_connection_id = each.value.peering_connection_id
  auto_accept               = true

  tags = {
    Name = "neves-labs-shared-to-${each.key}"
  }

  lifecycle {
    precondition {
      condition = (
        data.aws_vpc_peering_connection.client[each.key].owner_id == each.value.requester_account_id
        && data.aws_vpc_peering_connection.client[each.key].cidr_block == local.reserved_cidrs[each.key]
        && data.aws_vpc_peering_connection.client[each.key].peer_vpc_id == aws_vpc.shared.id
      )
      error_message = "Peering ${each.value.peering_connection_id} must come from account ${each.value.requester_account_id} with VPC range ${local.reserved_cidrs[each.key]}, and target the shared VPC. Recheck ${each.key}'s peering_connection_id against the client repo's `terraform output peering_connection_id`."
    }
  }
}

# Return path for each peered client, over its whole reserved range.
resource "aws_route" "client" {
  for_each = var.client_peerings

  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = local.reserved_cidrs[each.key]
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.client[each.key].vpc_peering_connection_id
}

resource "aws_db_subnet_group" "postgres" {
  name        = "neves-labs-pg"
  description = "Private subnets for neves-labs-pg"
  subnet_ids  = [for subnet in aws_subnet.private : subnet.id]

  lifecycle {
    prevent_destroy = true
  }
}
