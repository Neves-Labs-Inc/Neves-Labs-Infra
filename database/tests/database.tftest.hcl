mock_provider "aws" {
  override_data {
    target = data.aws_availability_zone.postgres
    values = {
      name    = "us-east-1a"
      zone_id = "use1-az1"
    }
  }
}

run "creates_a_small_encrypted_private_postgres_17_instance" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.identifier == "neves-labs-pg"
    error_message = "Instance identifier must be neves-labs-pg."
  }

  assert {
    condition     = aws_db_instance.postgres.engine == "postgres" && aws_db_instance.postgres.engine_version == "17"
    error_message = "Engine must be postgres version 17."
  }

  assert {
    condition     = aws_db_instance.postgres.instance_class == "db.t4g.micro"
    error_message = "Instance class must be db.t4g.micro."
  }

  assert {
    condition     = aws_db_instance.postgres.allocated_storage == 20 && aws_db_instance.postgres.storage_type == "gp3"
    error_message = "Storage must be 20 GB of gp3."
  }

  assert {
    condition     = aws_db_instance.postgres.storage_encrypted
    error_message = "Storage must be encrypted."
  }

  assert {
    condition     = aws_db_instance.postgres.multi_az == false
    error_message = "Instance must be single-AZ."
  }

  assert {
    condition     = aws_db_instance.postgres.publicly_accessible == false
    error_message = "Instance must not be publicly accessible."
  }
}

# db_name is computed, so it is unknown at plan. The override only fills computed
# values: a db_name set in config would still win and fail the assert.
run "logs_in_as_the_admin_user_without_an_initial_database" {
  command = apply

  override_resource {
    target = aws_db_instance.postgres
    values = {
      db_name = null
    }
  }

  assert {
    condition     = aws_db_instance.postgres.username == "neveslabs_admin"
    error_message = "Master username must be neveslabs_admin."
  }

  assert {
    condition     = aws_db_instance.postgres.db_name == null
    error_message = "RDS must create no initial database."
  }
}

run "places_the_instance_in_the_shared_network_by_az_id" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.db_subnet_group_name == "neves-labs-pg"
    error_message = "Instance must use the neves-labs-pg subnet group."
  }

  assert {
    condition     = aws_db_instance.postgres.vpc_security_group_ids == toset(["sg-0ba246dae19e683c9"])
    error_message = "Instance must use exactly the neves-labs-pg security group."
  }

  assert {
    condition     = aws_db_instance.postgres.availability_zone == "us-east-1a"
    error_message = "Instance must sit in the AZ name looked up from use1-az1."
  }
}

run "forces_tls_through_its_own_postgres_17_parameter_group" {
  command = plan

  assert {
    condition     = aws_db_parameter_group.postgres.family == "postgres17"
    error_message = "Parameter group family must be postgres17."
  }

  assert {
    condition = anytrue([
      for parameter in aws_db_parameter_group.postgres.parameter :
      parameter.name == "rds.force_ssl" && parameter.value == "1"
    ])
    error_message = "Parameter group must set rds.force_ssl to 1."
  }

  assert {
    condition     = aws_db_instance.postgres.parameter_group_name == "neves-labs-pg-postgres17"
    error_message = "Instance must use the neves-labs-pg-postgres17 parameter group."
  }
}

run "keeps_a_week_of_backups_and_performance_insights" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.backup_retention_period == 7
    error_message = "Backups must be kept for 7 days."
  }

  assert {
    condition     = aws_db_instance.postgres.performance_insights_enabled && aws_db_instance.postgres.performance_insights_retention_period == 7
    error_message = "Performance Insights must be enabled with 7-day retention."
  }

  assert {
    condition     = aws_db_instance.postgres.database_insights_mode == "standard"
    error_message = "Database Insights mode must be standard."
  }
}

run "guards_against_deletion_and_keeps_a_final_snapshot" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.deletion_protection
    error_message = "Deletion protection must be on."
  }

  assert {
    condition     = aws_db_instance.postgres.skip_final_snapshot == false
    error_message = "A final snapshot must be taken on destroy."
  }

  assert {
    condition     = aws_db_instance.postgres.final_snapshot_identifier == "neves-labs-pg-final"
    error_message = "Final snapshot must be named neves-labs-pg-final."
  }
}

run "generates_url_safe_32_character_passwords" {
  command = plan

  assert {
    condition     = random_password.admin.length == 32 && random_password.admin.special == false
    error_message = "Admin password must be 32 characters with no specials."
  }

  assert {
    condition     = random_password.client["tutorlink"].length == 32 && random_password.client["tutorlink"].special == false
    error_message = "The tutorlink client password must be 32 characters with no specials."
  }
}

run "exposes_the_connection_values_franklin_copies_into_client_roots" {
  command = apply

  assert {
    condition     = output.availability_zone_id == "use1-az1"
    error_message = "Output availability_zone_id must be use1-az1."
  }

  assert {
    condition     = output.admin_username == "neveslabs_admin"
    error_message = "Output admin_username must be neveslabs_admin."
  }

  assert {
    condition     = output.port == 5432
    error_message = "Output port must be 5432."
  }

  assert {
    # Checks tutorlink only, so adding a client to the registry needs no test change.
    condition     = lookup(output.client_connection_limits, "tutorlink", null) == 30
    error_message = "The default client registry must hold tutorlink, at 30 connections."
  }
}

run "maps_each_client_to_its_connection_limit_with_a_default_of_10" {
  command = apply
  # Own state: prevent_destroy would block later runs from dropping newclient.
  state_key = "two_clients"

  variables {
    clients = {
      tutorlink = { connection_limit = 30 }
      newclient = {}
    }
  }

  assert {
    condition     = output.client_connection_limits == { tutorlink = 30, newclient = 10 }
    error_message = "Connection limits must be tutorlink = 30 and newclient = 10 (the default)."
  }
}

run "exposes_one_password_per_client_keyed_by_name" {
  command = apply
  # Own state: prevent_destroy would block later runs from dropping newclient.
  state_key = "two_clients"

  variables {
    clients = {
      tutorlink = { connection_limit = 30 }
      newclient = {}
    }
  }

  assert {
    condition     = keys(output.client_passwords) == ["newclient", "tutorlink"]
    error_message = "client_passwords must be keyed by client name."
  }

  assert {
    condition     = nonsensitive(output.client_passwords["tutorlink"]) == nonsensitive(random_password.client["tutorlink"].result)
    error_message = "client_passwords must hold each client's generated password."
  }

  assert {
    condition     = issensitive(output.client_passwords)
    error_message = "client_passwords must be sensitive."
  }
}

run "rejects_a_client_name_uppercase" {
  command = plan

  variables {
    clients = {
      "TutorLink" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_hyphen" {
  command = plan

  variables {
    clients = {
      "tn-cleaning" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_leading_digit" {
  command = plan

  variables {
    clients = {
      "1client" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_64_characters" {
  command = plan

  variables {
    clients = {
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_postgres" {
  command = plan

  variables {
    clients = {
      "postgres" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_rdsadmin" {
  command = plan

  variables {
    clients = {
      "rdsadmin" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_neveslabs_admin" {
  command = plan

  variables {
    clients = {
      "neveslabs_admin" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_connection_limit_of_0" {
  command = plan

  variables {
    clients = {
      tutorlink = { connection_limit = 0 }
    }
  }

  expect_failures = [var.clients]
}

# -1 means unlimited in Postgres, which would bypass the connection budget.
run "rejects_a_connection_limit_of_minus_1" {
  command = plan

  variables {
    clients = {
      tutorlink = { connection_limit = -1 }
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_fractional_connection_limit" {
  command = plan

  variables {
    clients = {
      tutorlink = { connection_limit = 2.5 }
    }
  }

  expect_failures = [var.clients]
}

run "rejects_clients_whose_connection_limits_total_more_than_70" {
  command = plan

  variables {
    clients = {
      tutorlink = { connection_limit = 30 }
      client_a  = { connection_limit = 25 }
      client_b  = { connection_limit = 25 }
    }
  }

  expect_failures = [var.clients]
}

run "accepts_clients_whose_connection_limits_total_exactly_70" {
  command = plan
  # Own state: the default state holds every registry client, and dropping one trips prevent_destroy.
  state_key = "budget_70"

  variables {
    clients = {
      tutorlink = { connection_limit = 30 }
      client_a  = { connection_limit = 25 }
      client_b  = { connection_limit = 15 }
    }
  }

  assert {
    condition     = length(random_password.client) == 3
    error_message = "A total of exactly 70 connections must plan one password per client."
  }
}

run "rejects_a_client_name_rds_prefix" {
  command = plan

  variables {
    clients = {
      "rds_superuser" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_pg_prefix" {
  command = plan

  variables {
    clients = {
      "pg_monitor" = {}
    }
  }

  expect_failures = [var.clients]
}

run "rejects_a_client_name_template1" {
  command = plan

  variables {
    clients = {
      "template1" = {}
    }
  }

  expect_failures = [var.clients]
}
