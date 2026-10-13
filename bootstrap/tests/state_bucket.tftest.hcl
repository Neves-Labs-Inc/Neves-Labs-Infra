mock_provider "aws" {}

variables {
  state_account_id = "123456789012"
}

run "names_the_bucket_after_the_state_account" {
  command = apply

  assert {
    condition     = aws_s3_bucket.state.bucket == "neves-labs-tfstate-123456789012"
    error_message = "Bucket name must be neves-labs-tfstate-<state_account_id>."
  }

  assert {
    condition     = output.state_bucket == "neves-labs-tfstate-123456789012"
    error_message = "Output state_bucket must expose the bucket name."
  }
}

run "rejects_a_state_account_id_that_is_not_12_digits" {
  command = plan

  variables {
    state_account_id = "123"
  }

  expect_failures = [var.state_account_id]
}

run "hardens_the_bucket" {
  command = apply

  assert {
    condition     = one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled"
    error_message = "Versioning must be Enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Default encryption must be AES256."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "All four public access block flags must be true."
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.state.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "Object ownership must be BucketOwnerEnforced."
  }
}

run "denies_requests_without_tls" {
  command = apply

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      statement.Effect == "Deny"
      && statement.Action == "s3:*"
      && tostring(statement.Condition.Bool["aws:SecureTransport"]) == "false"
    ])
    error_message = "Bucket policy must deny s3:* when aws:SecureTransport is false."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      toset(statement.Resource) == toset([aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"])
    ])
    error_message = "The TLS deny must cover the bucket and its objects."
  }
}
