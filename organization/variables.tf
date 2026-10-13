locals {
  # Shape check only (x@y.z); AWS does the real verification.
  email_pattern = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"
}

variable "region" {
  description = "AWS region for the provider."
  type        = string
  default     = "us-east-1"
}

variable "account_emails" {
  description = "Root email for each member account. Kept out of the repo in terraform.tfvars."
  type = object({
    neves_labs       = string
    tutorlink_prod   = string
    tn_cleaning_prod = string
  })

  validation {
    condition = alltrue([
      for email in values(var.account_emails) : can(regex(local.email_pattern, email))
    ])
    error_message = "Every account email must look like name@domain.tld."
  }
}

variable "alert_email" {
  description = "Address that receives budget alerts."
  type        = string

  validation {
    condition     = can(regex(local.email_pattern, var.alert_email))
    error_message = "alert_email must look like name@domain.tld."
  }
}

variable "sso_user_name" {
  description = "Identity Center user name that gets AdministratorAccess on every member account."
  type        = string
}
