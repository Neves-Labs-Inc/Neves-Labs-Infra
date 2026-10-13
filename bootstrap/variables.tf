variable "state_account_id" {
  description = "Account ID of the Neves-Labs member account that holds the state bucket."
  type        = string
  default     = "277396470866"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.state_account_id))
    error_message = "state_account_id must be exactly 12 digits."
  }
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}
