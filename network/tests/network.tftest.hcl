mock_provider "aws" {}

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

run "opens_postgres_only_to_the_reserved_client_cidrs" {
  command = plan

  # Exactly one rule per reserved range, so a client added to reserved_cidrs needs no test change.
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres) == length(output.reserved_cidrs)
    error_message = "There must be exactly one Postgres ingress rule per reserved client CIDR."
  }

  assert {
    condition     = toset([for rule in aws_vpc_security_group_ingress_rule.postgres : rule.cidr_ipv4]) == toset(values(output.reserved_cidrs))
    error_message = "Ingress must come from exactly the reserved client CIDRs."
  }

  assert {
    condition     = length(setsubtract(["10.20.0.0/16", "10.30.0.0/16"], [for rule in aws_vpc_security_group_ingress_rule.postgres : rule.cidr_ipv4])) == 0
    error_message = "Ingress must include 10.20.0.0/16 (tutorlink-prod) and 10.30.0.0/16 (tn-cleaning-prod)."
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
