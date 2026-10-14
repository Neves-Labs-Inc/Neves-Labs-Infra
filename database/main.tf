# Pinned by AZ ID, not name: AZ names map to different physical zones per account.
data "aws_availability_zone" "postgres" {
  zone_id = local.availability_zone_id
}

# No special characters: passwords here go into connection URLs unencoded.
resource "random_password" "admin" {
  length  = 32
  special = false
}

# No special characters: each client password goes into a connection URL unencoded.
resource "random_password" "client" {
  for_each = var.clients

  length  = 32
  special = false

  # Removing a client from the map must not silently drop its password.
  lifecycle {
    prevent_destroy = true
  }
}

moved {
  from = random_password.tutorlink
  to   = random_password.client["tutorlink"]
}

resource "aws_db_parameter_group" "postgres" {
  name        = "neves-labs-pg-postgres17"
  family      = "postgres17"
  description = "neves-labs-pg settings: TLS is required on every connection."

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# No RDS Proxy: TutorLink holds a long-lived LISTEN connection, which a proxy breaks.
resource "aws_db_instance" "postgres" {
  identifier = "neves-labs-pg"

  engine                     = "postgres"
  engine_version             = "17"
  auto_minor_version_upgrade = true

  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  # AWS-managed RDS key: the instance is never shared by snapshot, so no customer key.
  storage_encrypted = true

  # No db_name: each client gets its own database and role, created later by SQL.
  username = local.admin_username
  password = random_password.admin.result

  port                   = local.postgres_port
  multi_az               = false
  availability_zone      = data.aws_availability_zone.postgres.name
  db_subnet_group_name   = local.db_subnet_group_name
  vpc_security_group_ids = [local.postgres_security_group_id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.postgres.name

  backup_retention_period = 7
  copy_tags_to_snapshot   = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  database_insights_mode                = "standard"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "neves-labs-pg-final"
}
