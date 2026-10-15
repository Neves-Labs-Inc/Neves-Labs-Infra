mock_provider "aws" {}

# Its own file so no file-level variables block overrides the real default: the
# committed default must keep failing the plan until a real peering ID is pasted in.
run "rejects_the_committed_placeholder_default" {
  command = plan

  expect_failures = [var.client_peerings]
}
