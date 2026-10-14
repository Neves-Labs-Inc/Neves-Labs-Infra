# The client registry: add a client here as one more entry. Never set it from
# tfvars or the CLI. A variable rather than a local so the validations live on it
# and tests can feed it other maps.
variable "clients" {
  description = "Clients sharing neves-labs-pg, keyed by name. The key is both the Postgres role and the database name."
  type = map(object({
    connection_limit = optional(number, 10)
  }))
  default = {
    tutorlink = { connection_limit = 30 }
  }

  # pg_ and rds prefixes belong to built-in Postgres and RDS roles (pg_monitor,
  # rdsadmin, rds_superuser); a client must never take over an existing role or database.
  validation {
    condition = alltrue([
      for name in keys(var.clients) :
      can(regex("^[a-z][a-z0-9_]{0,62}$", name)) &&
      !can(regex("^(pg_|rds)", name)) &&
      !contains(["postgres", "neveslabs_admin", "template0", "template1", "public"], name)
    ])
    error_message = "Each client name must be 1 to 63 characters of lowercase letters, digits and underscores, and start with a letter. It must not start with pg_ or rds, or be postgres, neveslabs_admin, template0, template1 or public. It becomes both a Postgres role and a database name."
  }

  # Postgres reads -1 as unlimited, which would slip past the connection budget below.
  validation {
    condition = alltrue([
      for client in values(var.clients) :
      client.connection_limit >= 1 && floor(client.connection_limit) == client.connection_limit
    ])
    error_message = "Each client connection_limit must be a whole number of at least 1."
  }

  # The server allows about 80 connections; the rest is headroom for admin and the
  # reserved slots. The leading 0 keeps sum() from failing on an empty map.
  validation {
    condition     = sum(concat([0], [for client in values(var.clients) : client.connection_limit])) <= 70
    error_message = "Client connection_limit values must total at most 70, leaving headroom on neves-labs-pg for admin and the reserved slots."
  }
}
