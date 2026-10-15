mock_provider "aws" {}

# A fixed shared VPC ID, so the peering lookups below can name it as the accepter side.
override_resource {
  target = aws_vpc.shared
  values = {
    id = "vpc-0aaaaaaaaaaaaaaaa"
  }
}

# What AWS reports for each pending peering: the requester's account and VPC range,
# and the shared VPC as the accepter.
override_data {
  target = data.aws_vpc_peering_connection.client["tutorlink-prod"]
  values = {
    owner_id    = "046451670022"
    cidr_block  = "10.20.0.0/16"
    peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
  }
}

override_data {
  target = data.aws_vpc_peering_connection.client["tn-cleaning-prod"]
  values = {
    owner_id    = "123456789012"
    cidr_block  = "10.30.0.0/16"
    peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
  }
}

# Every run starts from a fixed, valid-looking peering ID, independent of the real
# default in variables.tf.
variables {
  client_peerings = {
    tutorlink-prod = {
      peering_connection_id = "pcx-0123456789abcdef0"
      app_subnet_cidr       = "10.20.0.0/24"
      requester_account_id  = "046451670022"
    }
  }
}

run "creates_a_vpc_with_dns_enabled" {
  command = plan

  assert {
    condition     = aws_vpc.shared.cidr_block == "10.10.0.0/16"
    error_message = "VPC CIDR must be 10.10.0.0/16."
  }

  assert {
    condition     = aws_vpc.shared.enable_dns_support && aws_vpc.shared.enable_dns_hostnames
    error_message = "VPC must enable DNS support and DNS hostnames."
  }
}

run "creates_one_private_subnet_per_az_id_inside_the_vpc" {
  command = plan

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "There must be exactly 2 private subnets."
  }

  assert {
    condition     = toset([for subnet in aws_subnet.private : subnet.availability_zone_id]) == toset(["use1-az1", "use1-az2"])
    error_message = "Subnets must sit in AZ IDs use1-az1 and use1-az2."
  }

  assert {
    condition     = toset([for subnet in aws_subnet.private : subnet.cidr_block]) == toset(["10.10.0.0/24", "10.10.1.0/24"])
    error_message = "Subnet CIDRs must be 10.10.0.0/24 and 10.10.1.0/24."
  }

  assert {
    condition = alltrue([
      for subnet in aws_subnet.private :
      cidrhost("${split("/", subnet.cidr_block)[0]}/${split("/", aws_vpc.shared.cidr_block)[1]}", 0) == cidrhost(aws_vpc.shared.cidr_block, 0)
    ])
    error_message = "Every subnet must fall inside the VPC CIDR 10.10.0.0/16."
  }

  assert {
    condition     = alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false])
    error_message = "Subnets must not assign public IPs on launch."
  }
}

run "associates_the_private_route_table_with_both_subnets" {
  command = apply

  assert {
    condition     = length(aws_route_table_association.private) == 2
    error_message = "There must be exactly 2 route table associations."
  }

  assert {
    condition     = alltrue([for association in aws_route_table_association.private : association.route_table_id == aws_route_table.private.id])
    error_message = "Every association must point at the private route table."
  }

  assert {
    condition     = toset([for association in aws_route_table_association.private : association.subnet_id]) == toset([for subnet in aws_subnet.private : subnet.id])
    error_message = "The route table must be associated with both private subnets."
  }
}

run "strips_every_rule_from_the_default_security_group" {
  command = plan

  assert {
    condition     = length(aws_default_security_group.locked.ingress) == 0
    error_message = "The default security group must have no ingress rules."
  }

  assert {
    condition     = length(aws_default_security_group.locked.egress) == 0
    error_message = "The default security group must have no egress rules."
  }
}

# tn-cleaning-prod has a reserved range but no peering, so it gets no rule.
run "opens_postgres_only_to_each_peered_app_subnet" {
  command = plan

  assert {
    condition     = keys(aws_vpc_security_group_ingress_rule.postgres) == ["tutorlink-prod"]
    error_message = "There must be exactly one Postgres ingress rule, keyed tutorlink-prod."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres["tutorlink-prod"].cidr_ipv4 == "10.20.0.0/24"
    error_message = "Postgres ingress for tutorlink-prod must come from its app subnet 10.20.0.0/24 only."
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.postgres :
      rule.ip_protocol == "tcp" && rule.from_port == 5432 && rule.to_port == 5432
    ])
    error_message = "Every ingress rule must be TCP on port 5432."
  }
}

run "groups_both_private_subnets_for_postgres" {
  command = apply

  assert {
    condition     = aws_db_subnet_group.postgres.name == "neves-labs-pg"
    error_message = "DB subnet group must be named neves-labs-pg."
  }

  assert {
    condition     = toset(aws_db_subnet_group.postgres.subnet_ids) == toset([for subnet in aws_subnet.private : subnet.id])
    error_message = "DB subnet group must hold both private subnets."
  }
}

run "exposes_the_values_franklin_copies_into_client_roots" {
  command = apply

  assert {
    # Checks the known entries only, so adding a client's range needs no test change.
    condition = (
      lookup(output.reserved_cidrs, "tutorlink-prod", null) == "10.20.0.0/16"
      && lookup(output.reserved_cidrs, "tn-cleaning-prod", null) == "10.30.0.0/16"
    )
    error_message = "Output reserved_cidrs must map tutorlink-prod to 10.20.0.0/16 and tn-cleaning-prod to 10.30.0.0/16."
  }

  assert {
    condition     = output.db_subnet_group_name == "neves-labs-pg"
    error_message = "Output db_subnet_group_name must be neves-labs-pg."
  }

  assert {
    condition     = output.vpc_cidr == "10.10.0.0/16"
    error_message = "Output vpc_cidr must be 10.10.0.0/16."
  }

  assert {
    condition     = output.private_subnet_ids == { for az_id, subnet in aws_subnet.private : az_id => subnet.id }
    error_message = "Output private_subnet_ids must map each AZ ID to its subnet ID."
  }
}

# The reserved client ranges, this VPC and the AWS default VPC (172.31.0.0/16) must
# all be peerable with each other, so no two may overlap.
run "keeps_reserved_cidrs_clear_of_each_other_and_the_vpcs" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for i, a in concat(values(output.reserved_cidrs), [output.vpc_cidr, "172.31.0.0/16"]) : [
        for j, b in concat(values(output.reserved_cidrs), [output.vpc_cidr, "172.31.0.0/16"]) :
        cidrhost("${split("/", a)[0]}/${min(split("/", a)[1], split("/", b)[1])}", 0)
        != cidrhost("${split("/", b)[0]}/${min(split("/", a)[1], split("/", b)[1])}", 0)
        if i < j
      ]
    ]))
    error_message = "Reserved CIDRs, 10.10.0.0/16 and 172.31.0.0/16 must not overlap pairwise."
  }
}

run "accepts_each_client_peering" {
  command = plan

  assert {
    condition     = length(aws_vpc_peering_connection_accepter.client) == 1
    error_message = "There must be exactly one peering accepter per client peering."
  }

  assert {
    condition     = aws_vpc_peering_connection_accepter.client["tutorlink-prod"].vpc_peering_connection_id == "pcx-0123456789abcdef0"
    error_message = "The tutorlink-prod accepter must accept pcx-0123456789abcdef0."
  }

  assert {
    condition     = aws_vpc_peering_connection_accepter.client["tutorlink-prod"].auto_accept
    error_message = "The accepter must auto-accept the request."
  }

  assert {
    condition     = aws_vpc_peering_connection_accepter.client["tutorlink-prod"].tags["Name"] == "neves-labs-shared-to-tutorlink-prod"
    error_message = "The accepter must be tagged Name = neves-labs-shared-to-tutorlink-prod."
  }
}

run "routes_each_client_range_back_through_its_peering" {
  command = plan

  assert {
    condition     = length(aws_route.client) == 1
    error_message = "There must be exactly one route per client peering."
  }

  assert {
    condition     = aws_route.client["tutorlink-prod"].destination_cidr_block == "10.20.0.0/16"
    error_message = "The tutorlink-prod route must target its reserved range 10.20.0.0/16."
  }

  assert {
    condition     = aws_route.client["tutorlink-prod"].vpc_peering_connection_id == "pcx-0123456789abcdef0"
    error_message = "The tutorlink-prod route must go through pcx-0123456789abcdef0."
  }

  assert {
    condition     = aws_route.client["tutorlink-prod"].route_table_id == aws_route_table.private.id
    error_message = "The route must live in the private route table."
  }
}

run "limits_the_default_network_acl_to_postgres_from_each_app_subnet" {
  command = apply

  assert {
    condition     = aws_default_network_acl.private.default_network_acl_id == aws_vpc.shared.default_network_acl_id
    error_message = "The managed network ACL must be the shared VPC's default network ACL."
  }

  assert {
    condition     = toset(aws_default_network_acl.private.subnet_ids) == toset([for subnet in aws_subnet.private : subnet.id])
    error_message = "The default network ACL must list both private subnets."
  }

  assert {
    condition = [
      for rule in aws_default_network_acl.private.ingress :
      [rule.rule_no, rule.action, rule.protocol, rule.cidr_block, rule.from_port, rule.to_port]
    ] == [[210, "allow", "tcp", "10.20.0.0/24", 5432, 5432]]
    error_message = "Ingress must be exactly rule 210: allow TCP 5432 from 10.20.0.0/24."
  }

  assert {
    condition = [
      for rule in aws_default_network_acl.private.egress :
      [rule.rule_no, rule.action, rule.protocol, rule.cidr_block, rule.from_port, rule.to_port]
    ] == [[210, "allow", "tcp", "10.20.0.0/24", 1024, 65535]]
    error_message = "Egress must be exactly rule 210: allow TCP 1024-65535 to 10.20.0.0/24."
  }
}

run "gives_a_second_client_its_own_peering_route_and_rules" {
  command = plan

  variables {
    client_peerings = {
      tutorlink-prod = {
        peering_connection_id = "pcx-0123456789abcdef0"
        app_subnet_cidr       = "10.20.0.0/24"
        requester_account_id  = "046451670022"
      }
      tn-cleaning-prod = {
        peering_connection_id = "pcx-0fedcba9876543210"
        app_subnet_cidr       = "10.30.4.0/24"
        requester_account_id  = "123456789012"
      }
    }
  }

  assert {
    condition     = aws_vpc_peering_connection_accepter.client["tn-cleaning-prod"].vpc_peering_connection_id == "pcx-0fedcba9876543210"
    error_message = "The tn-cleaning-prod accepter must accept pcx-0fedcba9876543210."
  }

  assert {
    condition = (
      aws_route.client["tn-cleaning-prod"].destination_cidr_block == "10.30.0.0/16"
      && aws_route.client["tn-cleaning-prod"].vpc_peering_connection_id == "pcx-0fedcba9876543210"
    )
    error_message = "The tn-cleaning-prod route must send 10.30.0.0/16 through pcx-0fedcba9876543210."
  }

  assert {
    condition = {
      for client, rule in aws_vpc_security_group_ingress_rule.postgres : client => rule.cidr_ipv4
    } == { tutorlink-prod = "10.20.0.0/24", tn-cleaning-prod = "10.30.4.0/24" }
    error_message = "Postgres ingress must come from each client's app subnet, one rule per client."
  }

  # tutorlink-prod keeps rule 210, so adding a client never renumbers existing rules.
  assert {
    condition = toset([
      for rule in aws_default_network_acl.private.ingress :
      [rule.rule_no, rule.cidr_block, rule.from_port, rule.to_port]
    ]) == toset([[210, "10.20.0.0/24", 5432, 5432], [310, "10.30.4.0/24", 5432, 5432]])
    error_message = "Ingress must be rule 210 from 10.20.0.0/24 and rule 310 from 10.30.4.0/24, TCP 5432."
  }

  assert {
    condition = toset([
      for rule in aws_default_network_acl.private.egress :
      [rule.rule_no, rule.cidr_block, rule.from_port, rule.to_port]
    ]) == toset([[210, "10.20.0.0/24", 1024, 65535], [310, "10.30.4.0/24", 1024, 65535]])
    error_message = "Egress must be rule 210 to 10.20.0.0/24 and rule 310 to 10.30.4.0/24, TCP 1024-65535."
  }
}

run "rejects_the_placeholder_peering_id" {
  command = plan

  variables {
    client_peerings = {
      tutorlink-prod = {
        peering_connection_id = "pcx-SET-FROM-TUTORLINK-OUTPUT"
        app_subnet_cidr       = "10.20.0.0/24"
        requester_account_id  = "046451670022"
      }
    }
  }

  expect_failures = [var.client_peerings]
}

run "rejects_a_client_without_a_reserved_range" {
  command = plan

  variables {
    client_peerings = {
      acme-prod = {
        peering_connection_id = "pcx-0123456789abcdef0"
        app_subnet_cidr       = "10.40.0.0/24"
        requester_account_id  = "046451670022"
      }
    }
  }

  expect_failures = [var.client_peerings]
}

run "rejects_an_app_subnet_outside_the_client_range" {
  command = plan

  variables {
    client_peerings = {
      tutorlink-prod = {
        peering_connection_id = "pcx-0123456789abcdef0"
        app_subnet_cidr       = "10.30.0.0/24"
        requester_account_id  = "046451670022"
      }
    }
  }

  expect_failures = [var.client_peerings]
}

run "rejects_an_app_subnet_wider_than_the_client_range" {
  command = plan

  variables {
    client_peerings = {
      tutorlink-prod = {
        peering_connection_id = "pcx-0123456789abcdef0"
        app_subnet_cidr       = "10.0.0.0/8"
        requester_account_id  = "046451670022"
      }
    }
  }

  expect_failures = [var.client_peerings]
}

run "refuses_a_peering_requested_from_another_account" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.client["tutorlink-prod"]
    values = {
      owner_id    = "999999999999"
      cidr_block  = "10.20.0.0/16"
      peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.client]
}

run "refuses_a_peering_from_a_vpc_outside_the_client_range" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.client["tutorlink-prod"]
    values = {
      owner_id    = "046451670022"
      cidr_block  = "10.99.0.0/16"
      peer_vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.client]
}

run "refuses_a_peering_to_another_accepter_vpc" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.client["tutorlink-prod"]
    values = {
      owner_id    = "046451670022"
      cidr_block  = "10.20.0.0/16"
      peer_vpc_id = "vpc-0bbbbbbbbbbbbbbbb"
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.client]
}

run "rejects_a_malformed_requester_account_id" {
  command = plan

  variables {
    client_peerings = {
      tutorlink-prod = {
        peering_connection_id = "pcx-0123456789abcdef0"
        app_subnet_cidr       = "10.20.0.0/24"
        requester_account_id  = "4645167"
      }
    }
  }

  expect_failures = [var.client_peerings]
}
