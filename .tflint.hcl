# Shared by every Terraform root; CI points TFLINT_CONFIG_FILE at it because tflint
# only looks in the directory it runs from.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
