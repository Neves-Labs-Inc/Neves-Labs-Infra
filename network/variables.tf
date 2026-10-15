# The peering registry: a client's peering is one more entry here. Never set it from
# tfvars or the CLI. A variable rather than a local so the validations live on it
# and tests can feed it other maps.
variable "client_peerings" {
  description = "Client app VPC peerings into the shared VPC, keyed by the client's reserved_cidrs key. requester_account_id is the client account that requested the peering."
  type = map(object({
    peering_connection_id = string
    app_subnet_cidr       = string
    requester_account_id  = string
  }))
  default = {
    tutorlink-prod = {
      # Paste TutorLink's `terraform output peering_connection_id` (infra/) here.
      peering_connection_id = "pcx-0b03b59b6be07e388"
      app_subnet_cidr       = "10.20.0.0/24"
      # tutorlink-prod, the member account that owns TutorLink's app VPC.
      requester_account_id = "046451670022"
    }
  }

  # Fails the plan while a client's ID is still the placeholder, so no accepter is
  # ever applied against a peering that doesn't exist.
  validation {
    condition = alltrue([
      for peering in values(var.client_peerings) :
      can(regex("^pcx-[0-9a-f]+$", peering.peering_connection_id))
    ])
    error_message = "Each peering_connection_id must look like pcx-0123456789abcdef0. Set the client's peering_connection_id from the client repo's `terraform output peering_connection_id` (TutorLink: infra/)."
  }

  validation {
    condition = alltrue([
      for peering in values(var.client_peerings) :
      can(regex("^[0-9]{12}$", peering.requester_account_id))
    ])
    error_message = "Each requester_account_id must be the 12-digit ID of the client's AWS account, from `terraform output account_ids` in organization/."
  }

  # The reserved range is the route destination and the source of the network ACL rule numbers.
  validation {
    condition     = alltrue([for client in keys(var.client_peerings) : contains(keys(local.reserved_cidrs), client)])
    error_message = "Each client_peerings key must be a key of reserved_cidrs in network/locals.tf. Reserve the client's range there first."
  }

  # Inside means at least as narrow as the reserved range, with the same network address at
  # the range's prefix length. Unknown keys pass here; the validation above reports them.
  validation {
    condition = alltrue([
      for client, peering in var.client_peerings :
      !contains(keys(local.reserved_cidrs), client) || try(
        tonumber(split("/", peering.app_subnet_cidr)[1]) >= tonumber(split("/", local.reserved_cidrs[client])[1])
        && cidrhost("${split("/", peering.app_subnet_cidr)[0]}/${split("/", local.reserved_cidrs[client])[1]}", 0) == cidrhost(local.reserved_cidrs[client], 0),
        false
      )
    ])
    error_message = "Each app_subnet_cidr must be a CIDR inside its client's range in reserved_cidrs (tutorlink-prod: 10.20.0.0/16)."
  }
}
