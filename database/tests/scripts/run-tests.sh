#!/usr/bin/env bash
# Stub tests for database/set-database-url.sh, database/bootstrap-client.sh (the laptop-side driver) and database/remote/bootstrap-client-server.sh
# (the host-side script it sends through Run Command). No AWS, no network, no real psql.
#
# Usage: bash database/tests/scripts/run-tests.sh
#
# Each case runs in its own sandbox whose PATH holds only the stubs in stubs/ (aws, terraform, docker, sleep) and
# links to a few basic tools, so a real aws, terraform or docker can never be reached. The fake aws runs the
# command sent with send-command locally, so a successful case exercises the whole chain: staging, packaging,
# decoding on the "host", the server script, and cleanup.
#
# Exits non-zero if any case fails.
set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS_DIR
REPO_ROOT="$(cd "${SCRIPTS_DIR}/../../.." && pwd)"
readonly REPO_ROOT
readonly DRIVER="${REPO_ROOT}/database/bootstrap-client.sh"
readonly URL_SCRIPT="${REPO_ROOT}/database/set-database-url.sh"
readonly SERVER_SCRIPT="${REPO_ROOT}/database/remote/bootstrap-client-server.sh"
readonly CLIENT_SQL="${REPO_ROOT}/database/sql/client.sql"
readonly STUBS_DIR="${SCRIPTS_DIR}/stubs"

# Distinct, and full of the characters that break naive quoting.
readonly ADMIN_PASSWORD="adm'in \"pass\" one \$HOME"
readonly CLIENT_PASSWORD="cli'ent \"pass\" two \`x\`"

readonly CLIENT="acme"
readonly PROFILE="acme-prod"
readonly INSTANCE_ID="i-0123456789abcdef0"
readonly PREFIX="/acme/prod"
readonly ADDRESS="neves-labs-pg.example.us-east-1.rds.amazonaws.com"
readonly CONNECTION_LIMIT=30
readonly URL_PARAMETER="/acme/prod/DATABASE_URL"
readonly ADMIN_PARAMETER="${PREFIX}-bootstrap/NEVESLABS_ADMIN_PASSWORD"
readonly CLIENT_PARAMETER="${PREFIX}-bootstrap/CLIENT_DB_PASSWORD"

# Tools the scripts under test may use besides the stubs. jq is a stub that logs, then runs the real one.
readonly SYSTEM_TOOLS=(env mktemp rm cat dirname base64 tr sh find wc cp mkdir grep)

failed_cases=0
case_count=0
is_case_failed=false
sandbox=""
exit_code=0

# --- Sandbox and runners ------------------------------------------------------------------------------------------

# Builds a fresh sandbox. Stubs named in $1 (space-separated) are left out, to simulate a missing tool.
create_sandbox() {
  local missing_stubs="${1:-}" stub tool name
  sandbox="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-tests.XXXXXX")"
  mkdir -p "${sandbox}/bin" "${sandbox}/tmp" "${sandbox}/state"
  for stub in "${STUBS_DIR}"/*.sh; do
    name="$(basename "$stub" .sh)"
    [[ " ${missing_stubs} " == *" ${name} "* ]] && continue
    cp "$stub" "${sandbox}/bin/${name}"
    chmod +x "${sandbox}/bin/${name}"
  done
  for tool in "${SYSTEM_TOOLS[@]}"; do
    ln -s "$(command -v "$tool")" "${sandbox}/bin/${tool}"
  done
  # The bash running the tests is the bash under test, on the "laptop" and on the "host".
  ln -s "$BASH" "${sandbox}/bin/bash"
}

# Shared environment: the default terraform outputs for a known client, and the sandbox PATH.
# AWS_PROFILE is set so tests can check the driver drops it for terraform.
sandbox_env() {
  local client_passwords admin_password
  client_passwords="$(jq -cn --arg password "$CLIENT_PASSWORD" '{acme: $password, other: "other-password"}')"
  admin_password="$(jq -cn --arg password "$ADMIN_PASSWORD" '$password')"
  echo "PATH=${sandbox}/bin"
  echo "TMPDIR=${sandbox}/tmp"
  echo "STUB_STATE_DIR=${sandbox}/state"
  echo "STUB_REAL_JQ=$(command -v jq)"
  echo "AWS_PROFILE=management-profile-must-be-dropped"
  echo "STUB_TF_CLIENT_CONNECTION_LIMITS={\"acme\":${CONNECTION_LIMIT},\"other\":10}"
  echo "STUB_TF_CLIENT_PASSWORDS=${client_passwords}"
  echo "STUB_TF_ADMIN_PASSWORD=${admin_password}"
  echo "STUB_TF_ADDRESS=\"${ADDRESS}\""
}

# Runs a script in the sandbox. Arguments: env assignments (overriding the defaults), then --, then the command.
run_in_sandbox() {
  local assignments=()
  local line
  while IFS= read -r line; do
    assignments+=("$line")
  done < <(sandbox_env)
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    assignments+=("$1")
    shift
  done
  shift
  (cd "$sandbox" && env -i "${assignments[@]}" "$BASH" "$@" >"${sandbox}/stdout" 2>"${sandbox}/stderr")
  exit_code=$?
}

calls_log() {
  cat "${sandbox}/state/calls.log" 2>/dev/null
}

# --- Assertions ---------------------------------------------------------------------------------------------------

report_failure() {
  echo "    FAIL: $1"
  is_case_failed=true
}

assert_exit_code() {
  local expected="$1"
  [[ "$exit_code" == "$expected" ]] || report_failure "exit code ${exit_code}, expected ${expected}"
}

assert_exit_nonzero() {
  [[ "$exit_code" != 0 ]] || report_failure "exit code 0, expected non-zero"
}

assert_file_contains() {
  local file="$1" needle="$2"
  grep -qF -- "$needle" "$file" 2>/dev/null || report_failure "$(basename "$file") lacks: ${needle}"
}

assert_file_lacks() {
  local file="$1" needle="$2"
  ! grep -qF -- "$needle" "$file" 2>/dev/null || report_failure "$(basename "$file") contains: ${needle}"
}

assert_stdout_contains() { assert_file_contains "${sandbox}/stdout" "$1"; }
assert_stderr_contains() { assert_file_contains "${sandbox}/stderr" "$1"; }

assert_count() {
  local description="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || report_failure "${description}: ${actual}, expected ${expected}"
}

assert_no_aws_call() {
  assert_count "aws calls" 0 "$(calls_log | grep -c '^aws ')"
}

assert_parameters_deleted() {
  assert_count "delete-parameters calls naming both parameters" 1 \
    "$(calls_log | grep '^aws ssm delete-parameters' | grep -F -- "$ADMIN_PARAMETER" | grep -cF -- "$CLIENT_PARAMETER")"
}

# Checked after every case: no password anywhere it could leak, and no temporary file left behind.
assert_no_leaks() {
  local password file
  for password in "$ADMIN_PASSWORD" "$CLIENT_PASSWORD"; do
    for file in "${sandbox}/state/calls.log" "${sandbox}/stdout" "${sandbox}/stderr" \
      "${sandbox}/state/captured"/send-command-*.json; do
      [[ -f "$file" ]] || continue
      grep -qF -- "$password" "$file" && report_failure "a password leaked into $(basename "$file")"
    done
  done
  [[ -z "$(ls -A "${sandbox}/tmp")" ]] || report_failure "temporary files left: $(ls -A "${sandbox}/tmp")"
}

# --- Case runner --------------------------------------------------------------------------------------------------

run_case() {
  local name="$1"
  case_count=$((case_count + 1))
  is_case_failed=false
  "$name"
  if [[ "$is_case_failed" == true ]]; then
    failed_cases=$((failed_cases + 1))
    echo "not ok - ${name}"
    echo "    stdout: $(cat "${sandbox}/stdout" 2>/dev/null)"
    echo "    stderr: $(cat "${sandbox}/stderr" 2>/dev/null)"
  else
    echo "ok - ${name}"
  fi
  rm -rf "$sandbox"
}

# --- set-database-url.sh cases -------------------------------------------------------------------------------------

url_script_help_prints_usage_and_exits_0() {
  create_sandbox
  run_in_sandbox -- "$URL_SCRIPT" --help
  assert_exit_code 0
  assert_stdout_contains "Usage: database/set-database-url.sh <client> <aws-profile> <parameter-name> [scheme]"
  run_in_sandbox -- "$URL_SCRIPT" -h
  assert_exit_code 0
  assert_no_aws_call
  assert_no_leaks
}

url_script_rejects_a_wrong_argument_count_with_usage() {
  create_sandbox
  run_in_sandbox -- "$URL_SCRIPT" "$CLIENT" "$PROFILE"
  assert_exit_code 1
  assert_stderr_contains "Usage: database/set-database-url.sh"
  run_in_sandbox -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER" postgresql extra
  assert_exit_code 1
  assert_stderr_contains "Usage: database/set-database-url.sh"
  assert_count "calls" 0 "$(calls_log | wc -l | tr -d ' ')"
  assert_no_leaks
}

url_script_rejects_a_bad_scheme() {
  local scheme
  create_sandbox
  # shellcheck disable=SC2016 # the $(id) must stay literal: it's a scheme that must be refused
  for scheme in "Postgresql" "1pg" "pg_sql" "post gres" '$(id)' "" "postgresql:"; do
    run_in_sandbox -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER" "$scheme"
    assert_exit_code 1
    assert_stderr_contains "set-database-url: invalid scheme"
  done
  assert_no_aws_call
  assert_no_leaks
}

url_script_rejects_a_parameter_name_without_a_leading_slash() {
  create_sandbox
  run_in_sandbox -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "acme/prod/DATABASE_URL"
  assert_exit_code 1
  assert_stderr_contains "set-database-url: the parameter name must start with /acme/ or /acme/"
  assert_no_aws_call
  assert_no_leaks
}

url_script_rejects_a_parameter_name_of_another_client_before_any_call() {
  local name
  create_sandbox
  for name in "/other/prod/DATABASE_URL" "/acmex/prod/DATABASE_URL" "/acme" "/acme-prod/DATABASE_URL"; do
    run_in_sandbox -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$name"
    assert_exit_code 1
    assert_stderr_contains "set-database-url: the parameter name must start with /acme/ or /acme/"
  done
  assert_count "calls" 0 "$(calls_log | wc -l | tr -d ' ')"
  assert_no_leaks
}

url_script_accepts_the_hyphen_variant_of_an_underscore_client() {
  local name
  create_sandbox
  for name in "/tn_cleaning/prod/DATABASE_URL" "/tn-cleaning/prod/DATABASE_URL"; do
    run_in_sandbox 'STUB_TF_CLIENT_CONNECTION_LIMITS={"tn_cleaning":10}' \
      "STUB_TF_CLIENT_PASSWORDS={\"tn_cleaning\":\"pw\"}" -- "$URL_SCRIPT" tn_cleaning "$PROFILE" "$name"
    assert_exit_code 0
    assert_stdout_contains "${name} set, version 1"
  done
  run_in_sandbox 'STUB_TF_CLIENT_CONNECTION_LIMITS={"tn_cleaning":10}' -- "$URL_SCRIPT" tn_cleaning "$PROFILE" "/tn_other/prod/DATABASE_URL"
  assert_exit_code 1
  assert_stderr_contains "must start with /tn_cleaning/ or /tn-cleaning/"
  assert_no_leaks
}

url_script_rejects_an_unknown_client_before_any_aws_call() {
  create_sandbox
  run_in_sandbox -- "$URL_SCRIPT" nobody "$PROFILE" "/nobody/prod/DATABASE_URL"
  assert_exit_code 1
  assert_stderr_contains "set-database-url: unknown client 'nobody'. Known clients: acme, other"
  assert_no_aws_call
  assert_no_leaks
}

url_script_rejects_an_empty_clients_map_before_any_aws_call() {
  create_sandbox
  run_in_sandbox STUB_TF_CLIENT_CONNECTION_LIMITS='{}' -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER"
  assert_exit_code 1
  assert_stderr_contains "set-database-url: the clients map in database/variables.tf is empty: add the client there and apply database/ first"
  assert_no_aws_call
  assert_no_leaks
}

url_script_rejects_an_empty_or_null_password_or_address_before_any_aws_call() {
  local override
  create_sandbox
  for override in 'STUB_TF_CLIENT_PASSWORDS={"acme":null}' 'STUB_TF_CLIENT_PASSWORDS={"acme":""}' \
    'STUB_TF_ADDRESS=null' 'STUB_TF_ADDRESS=""'; do
    run_in_sandbox "$override" -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER"
    assert_exit_code 1
    assert_stderr_contains "is empty or null"
  done
  assert_no_aws_call
  assert_no_leaks
}

# Checks the captured put-parameter input against the expected value.
assert_url_parameter_value() {
  local expected_value="$1"
  jq -e --arg name "$URL_PARAMETER" --arg value "$expected_value" \
    '.Name == $name and .Type == "SecureString" and .Overwrite == true and .Value == $value' \
    "${sandbox}/state/captured/put-parameter-1.json" >/dev/null || report_failure "the DATABASE_URL parameter file is wrong"
}

url_script_writes_the_default_scheme_url_and_prints_only_the_version() {
  local log
  create_sandbox
  run_in_sandbox STUB_AWS_PUT_VERSION=42 -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER"
  log="$(calls_log)"
  assert_exit_code 0
  assert_url_parameter_value "postgresql://${CLIENT}:${CLIENT_PASSWORD}@${ADDRESS}:5432/${CLIENT}?sslmode=require"
  [[ "$(cat "${sandbox}/stdout")" == "${URL_PARAMETER} set, version 42" ]] || report_failure "stdout is not exactly the status line"
  assert_count "terraform calls with AWS_PROFILE set" 0 "$(grep '^terraform ' <<<"$log" | grep -vc 'AWS_PROFILE=<unset>')"
  assert_count "put-parameter calls from a file with the profile, region, query and output" 1 \
    "$(grep '^aws ssm put-parameter' <<<"$log" | grep -F -- "--profile ${PROFILE}" | grep -F -- '--region us-east-1' \
      | grep -F -- '--cli-input-json file://' | grep -F -- '--query Version' | grep -cF -- '--output text')"
  assert_count "aws calls" 1 "$(grep -c '^aws ' <<<"$log")"
  assert_no_leaks
}

url_script_uses_the_given_scheme() {
  create_sandbox
  run_in_sandbox -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER" postgresql+psycopg
  assert_exit_code 0
  assert_url_parameter_value "postgresql+psycopg://${CLIENT}:${CLIENT_PASSWORD}@${ADDRESS}:5432/${CLIENT}?sslmode=require"
  assert_no_leaks
}

url_script_fails_when_the_put_fails_and_leaves_no_file() {
  create_sandbox
  run_in_sandbox STUB_AWS_FAIL_PUT=1 -- "$URL_SCRIPT" "$CLIENT" "$PROFILE" "$URL_PARAMETER"
  assert_exit_nonzero
  assert_stderr_contains "set-database-url: "
  assert_file_lacks "${sandbox}/stdout" "set, version"
  assert_no_leaks
}

# --- Driver cases -------------------------------------------------------------------------------------------------

driver_help_prints_usage_and_exits_0() {
  create_sandbox
  run_in_sandbox -- "$DRIVER" --help
  assert_exit_code 0
  assert_stdout_contains "Usage: database/bootstrap-client.sh <client> <aws-profile> <instance-id> <parameter-prefix>"
  run_in_sandbox -- "$DRIVER" -h
  assert_exit_code 0
  assert_no_leaks
}

driver_rejects_a_wrong_argument_count_with_usage() {
  create_sandbox
  run_in_sandbox -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID"
  assert_exit_code 1
  assert_stderr_contains "Usage: database/bootstrap-client.sh"
  assert_count "calls" 0 "$(calls_log | wc -l | tr -d ' ')"
  assert_no_leaks
}

driver_rejects_a_bad_parameter_prefix_with_usage() {
  local prefix
  create_sandbox
  # shellcheck disable=SC2016 # the $(id) must stay literal: it's a prefix that must be refused
  for prefix in "acme/prod" "/acme/prod/" "/" "/acme//prod" "/acme prod" '/acme/$(id)' "/acme/'x"; do
    run_in_sandbox -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$prefix"
    assert_exit_code 1
    assert_stderr_contains "Usage: database/bootstrap-client.sh"
  done
  assert_no_aws_call
  assert_no_leaks
}

driver_rejects_an_unknown_client_before_any_aws_call() {
  create_sandbox
  run_in_sandbox -- "$DRIVER" nobody "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 1
  assert_stderr_contains "bootstrap-client: unknown client 'nobody'. Known clients: acme, other"
  assert_no_aws_call
  assert_no_leaks
}

driver_rejects_an_empty_clients_map_before_any_aws_call() {
  create_sandbox
  run_in_sandbox STUB_TF_CLIENT_CONNECTION_LIMITS='{}' -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 1
  assert_stderr_contains "bootstrap-client: the clients map in database/variables.tf is empty: add the client there and apply database/ first"
  assert_no_aws_call
  assert_no_leaks
}

driver_rejects_empty_or_null_secrets_and_address_before_any_aws_call() {
  local override
  create_sandbox
  for override in 'STUB_TF_CLIENT_PASSWORDS={"acme":null}' 'STUB_TF_CLIENT_PASSWORDS={"acme":""}' \
    'STUB_TF_ADMIN_PASSWORD=null' 'STUB_TF_ADMIN_PASSWORD=""' 'STUB_TF_ADDRESS=null' 'STUB_TF_ADDRESS=""'; do
    run_in_sandbox "$override" -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
    assert_exit_code 1
    assert_stderr_contains "bootstrap-client: "
    assert_stderr_contains "is empty or null"
  done
  assert_no_aws_call
  assert_no_leaks
}

driver_bootstraps_the_client_and_cleans_up() {
  local log driver_calls
  create_sandbox
  # The invocation is not visible at first, then still running, then done.
  run_in_sandbox STUB_AWS_POLL_ERRORS=1 STUB_AWS_PENDING_POLLS=2 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  log="$(calls_log)"
  assert_exit_code 0

  # Terraform is read with the management default profile.
  assert_count "terraform calls with AWS_PROFILE set" 0 "$(grep '^terraform ' <<<"$log" | grep -vc 'AWS_PROFILE=<unset>')"

  # Every driver-side aws call targets the client profile in us-east-1.
  driver_calls="$(grep -E '^aws ssm (put-parameter|send-command|get-command-invocation|delete-parameters) ' <<<"$log")"
  assert_count "driver aws calls without --profile ${PROFILE}" 0 "$(grep -vcF -- "--profile ${PROFILE}" <<<"$driver_calls")"
  assert_count "driver aws calls without --region us-east-1" 0 "$(grep -vcF -- "--region us-east-1" <<<"$driver_calls")"

  # Two put-parameter calls, each from a file.
  assert_count "put-parameter calls with --cli-input-json file://" 2 \
    "$(grep '^aws ssm put-parameter' <<<"$log" | grep -cF -- '--cli-input-json file://')"
  jq -e --arg name "$ADMIN_PARAMETER" --arg value "$ADMIN_PASSWORD" \
    '.Name == $name and .Type == "SecureString" and .Overwrite == true and .Value == $value' \
    "${sandbox}/state/captured/put-parameter-1.json" >/dev/null || report_failure "the admin parameter file is wrong"
  jq -e --arg name "$CLIENT_PARAMETER" --arg value "$CLIENT_PASSWORD" \
    '.Name == $name and .Type == "SecureString" and .Overwrite == true and .Value == $value' \
    "${sandbox}/state/captured/put-parameter-2.json" >/dev/null || report_failure "the client parameter file is wrong"

  # One send-command to the instance, then polling, then the delete.
  assert_count "send-command calls to the instance" 1 \
    "$(grep '^aws ssm send-command' <<<"$log" | grep -F -- "--instance-ids ${INSTANCE_ID}" \
      | grep -F -- '--document-name AWS-RunShellScript' | grep -F -- "--comment neves-labs bootstrap: ${CLIENT}" \
      | grep -cF -- '--parameters file://')"
  jq -e '.executionTimeout == ["600"] and (.commands | length) == 1' \
    "${sandbox}/state/captured/send-command-1.json" >/dev/null || report_failure "the send-command parameters are wrong"
  assert_count "get-command-invocation calls" 4 "$(grep -c '^aws ssm get-command-invocation' <<<"$log")"
  assert_count "polls that waited 5 seconds" 4 "$(grep -c '^sleep 5$' <<<"$log")"
  assert_parameters_deleted
  [[ "$(grep -n '' <<<"$log" | grep 'delete-parameters' | cut -d: -f1)" -gt \
    "$(grep -n '' <<<"$log" | grep 'send-command' | cut -d: -f1)" ]] || report_failure "delete-parameters ran before send-command"
  [[ -z "$(ls -A "${sandbox}/state/parameters")" ]] || report_failure "staged parameters remain in the store"

  # The host ran the server script with only non-secret arguments, and its output came back.
  assert_file_contains "${sandbox}/state/calls.log" "aws ssm get-parameter --region us-east-1 --name ${ADMIN_PARAMETER}"
  assert_stdout_contains "stub listing for \\du ${CLIENT}"
  assert_stdout_contains "stub listing for \\l ${CLIENT}"
  assert_stdout_contains "[${CLIENT}] bootstrap: Success"
  assert_no_leaks
}

driver_reports_a_rejected_instance_and_still_cleans_up() {
  create_sandbox
  run_in_sandbox STUB_AWS_FAIL_SEND_COMMAND=1 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 1
  assert_stderr_contains "bootstrap-client: Run Command rejected instance ${INSTANCE_ID} in profile ${PROFILE}: check that it is an online Systems Manager managed node and that the login hasn't expired"
  assert_parameters_deleted
  assert_no_leaks
}

driver_fails_when_the_command_fails_and_still_cleans_up() {
  create_sandbox
  run_in_sandbox STUB_DOCKER_FAIL=1 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_nonzero
  assert_stdout_contains "[${CLIENT}] bootstrap: Failed"
  assert_stderr_contains "psql: error: connection to server failed"
  assert_parameters_deleted
  assert_no_leaks
}

driver_times_out_after_ten_minutes_and_still_cleans_up() {
  create_sandbox
  run_in_sandbox STUB_AWS_PENDING_POLLS=1000 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 1
  assert_stderr_contains "bootstrap-client: timed out after 600 seconds waiting for command stub-command-id on ${INSTANCE_ID}"
  assert_count "polls" 120 "$(calls_log | grep -c '^aws ssm get-command-invocation')"
  assert_parameters_deleted
  assert_no_leaks
}

driver_warns_and_fails_when_the_cleanup_delete_fails() {
  create_sandbox
  run_in_sandbox STUB_AWS_FAIL_DELETE=1 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_nonzero
  assert_stdout_contains "[${CLIENT}] bootstrap: Success"
  assert_stderr_contains "${ADMIN_PARAMETER}"
  assert_stderr_contains "aws ssm delete-parameters --profile ${PROFILE} --region us-east-1 --names ${ADMIN_PARAMETER} ${CLIENT_PARAMETER}"
  assert_no_leaks
}

check_terminal_status() {
  local status="$1"
  create_sandbox
  run_in_sandbox STUB_AWS_FINAL_STATUS="$status" -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_nonzero
  assert_stdout_contains "[${CLIENT}] bootstrap: ${status}"
  assert_parameters_deleted
  assert_no_leaks
}

driver_fails_on_a_cancelled_command_and_still_cleans_up() { check_terminal_status Cancelled; }
driver_fails_on_a_timed_out_command_and_still_cleans_up() { check_terminal_status TimedOut; }

driver_keeps_polling_while_delayed() {
  create_sandbox
  run_in_sandbox STUB_AWS_PENDING_POLLS=3 STUB_AWS_PENDING_STATUS=Delayed -- \
    "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 0
  assert_count "get-command-invocation calls" 4 "$(calls_log | grep -c '^aws ssm get-command-invocation')"
  assert_stdout_contains "[${CLIENT}] bootstrap: Success"
  assert_no_leaks
}

driver_fails_fast_when_the_login_expires_while_polling() {
  create_sandbox
  run_in_sandbox STUB_AWS_POLL_ERRORS=1 STUB_AWS_POLL_ERROR=ExpiredTokenException -- \
    "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 1
  assert_stderr_contains "ExpiredTokenException"
  assert_stderr_contains "bootstrap-client: could not check command stub-command-id on ${INSTANCE_ID}: refresh your login for profile ${PROFILE}"
  assert_count "get-command-invocation calls" 1 "$(calls_log | grep -c '^aws ssm get-command-invocation')"
  assert_parameters_deleted
  assert_no_leaks
}

driver_warns_even_when_interrupted_during_cleanup() {
  create_sandbox
  run_in_sandbox STUB_AWS_FAIL_DELETE=1 STUB_AWS_INTERRUPT_ON_DELETE=1 -- \
    "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_nonzero
  assert_stderr_contains "aws ssm delete-parameters --profile ${PROFILE} --region us-east-1 --names ${ADMIN_PARAMETER} ${CLIENT_PARAMETER}"
  assert_no_leaks
}

# The failed put is still deleted, in case it landed; AWS answers with InvalidParameters and no error.
driver_cleans_up_a_failed_put_without_a_false_warning() {
  create_sandbox
  run_in_sandbox STUB_AWS_FAIL_PUT=1 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 254
  assert_file_lacks "${sandbox}/stderr" "WARNING"
  assert_count "delete-parameters calls naming the admin parameter" 1 \
    "$(calls_log | grep '^aws ssm delete-parameters' | grep -cF -- "--names ${ADMIN_PARAMETER}")"
  assert_count "send-command calls" 0 "$(calls_log | grep -c '^aws ssm send-command')"
  assert_no_leaks
}

driver_deletes_a_parameter_whose_put_was_interrupted() {
  create_sandbox
  run_in_sandbox STUB_AWS_INTERRUPT_ON_PUT=1 -- "$DRIVER" "$CLIENT" "$PROFILE" "$INSTANCE_ID" "$PREFIX"
  assert_exit_code 130
  assert_count "send-command calls" 0 "$(calls_log | grep -c '^aws ssm send-command')"
  assert_count "delete-parameters calls naming the admin parameter" 1 \
    "$(calls_log | grep '^aws ssm delete-parameters' | grep -cF -- "--names ${ADMIN_PARAMETER}")"
  [[ -z "$(ls -A "${sandbox}/state/parameters")" ]] || report_failure "the interrupted put's parameter remains"
  assert_no_leaks
}

# --- Server script cases ------------------------------------------------------------------------------------------

# The driver decodes the server script and client.sql side by side; mirror that layout.
stage_server_files() {
  mkdir -p "${sandbox}/host"
  cp "$SERVER_SCRIPT" "${sandbox}/host/bootstrap-client-server.sh"
  cp "$CLIENT_SQL" "${sandbox}/host/client.sql"
}

# Puts a value in the fake parameter store, as the driver would have.
stage_parameter() {
  mkdir -p "${sandbox}/state/parameters"
  printf '%s' "$2" >"${sandbox}/state/parameters/${1//\//__}"
}

run_server() {
  run_in_sandbox -- "${sandbox}/host/bootstrap-client-server.sh" \
    "$ADDRESS" "$CLIENT" "$CONNECTION_LIMIT" "$ADMIN_PARAMETER" "$CLIENT_PARAMETER"
}

server_fails_readably_without_docker() {
  create_sandbox docker
  stage_server_files
  run_server
  assert_exit_code 1
  assert_stderr_contains "bootstrap (server): docker is not installed"
  assert_no_leaks
}

server_fails_readably_without_the_aws_cli() {
  create_sandbox aws
  stage_server_files
  run_server
  assert_exit_code 1
  assert_stderr_contains "bootstrap (server): the AWS CLI is not installed"
  assert_no_leaks
}

server_fails_on_an_empty_staged_value() {
  create_sandbox
  stage_server_files
  stage_parameter "$ADMIN_PARAMETER" "$ADMIN_PASSWORD"
  stage_parameter "$CLIENT_PARAMETER" ""
  run_server
  assert_exit_code 1
  assert_stderr_contains "bootstrap (server): "
  assert_stderr_contains "$CLIENT_PARAMETER"
  assert_count "docker calls" 0 "$(calls_log | grep -c '^docker ')"
  assert_no_leaks
}

server_streams_the_password_line_and_client_sql_into_psql() {
  local stdin_capture
  create_sandbox
  stdin_capture="${sandbox}/state/captured/docker-stdin-1"
  stage_server_files
  stage_parameter "$ADMIN_PARAMETER" "$ADMIN_PASSWORD"
  stage_parameter "$CLIENT_PARAMETER" "$CLIENT_PASSWORD"
  run_server
  assert_exit_code 0

  [[ "$(head -n 1 "$stdin_capture")" == '\getenv client_password CLIENT_PASSWORD' ]] \
    || report_failure "psql stdin does not start with the \\getenv line"
  tail -n +2 "$stdin_capture" | cmp -s - "$CLIENT_SQL" || report_failure "psql stdin after the first line is not client.sql"

  [[ "$(cat "${sandbox}/state/captured/docker-env-PGPASSWORD-1")" == "$ADMIN_PASSWORD" ]] \
    || report_failure "psql did not get the admin password as PGPASSWORD"
  [[ "$(cat "${sandbox}/state/captured/docker-env-CLIENT_PASSWORD-1")" == "$CLIENT_PASSWORD" ]] \
    || report_failure "psql did not get the client password as CLIENT_PASSWORD"

  # Pinned image; VERBOSITY=terse keeps a failing role statement (and its password) out of psql's error output.
  assert_file_contains "${sandbox}/state/calls.log" \
    "docker run --rm -i --network host -e PGPASSWORD -e CLIENT_PASSWORD postgres:17-alpine@sha256:"
  assert_file_contains "${sandbox}/state/calls.log" \
    "psql -X host=${ADDRESS} port=5432 dbname=postgres user=neveslabs_admin sslmode=require -v VERBOSITY=terse -v client=${CLIENT} -v connection_limit=${CONNECTION_LIMIT} -f -"
  assert_file_contains "${sandbox}/state/calls.log" "docker run --rm --network host -e PGPASSWORD postgres:17-alpine@sha256:"
  assert_file_contains "${sandbox}/state/calls.log" \
    "psql -X host=${ADDRESS} port=5432 dbname=postgres user=neveslabs_admin sslmode=require -c \\du ${CLIENT} -c \\l ${CLIENT}"
  assert_stdout_contains "stub listing for \\du ${CLIENT}"
  assert_no_leaks
}

# --- Main ---------------------------------------------------------------------------------------------------------

# A missing tool would make cases pass or fail for the wrong reason.
for tool in "${SYSTEM_TOOLS[@]}" jq; do
  command -v "$tool" >/dev/null || { echo "run-tests: ${tool} is not installed" >&2; exit 1; }
done

echo "bash ${BASH_VERSION}"
for test_case in \
  url_script_help_prints_usage_and_exits_0 \
  url_script_rejects_a_wrong_argument_count_with_usage \
  url_script_rejects_a_bad_scheme \
  url_script_rejects_a_parameter_name_without_a_leading_slash \
  url_script_rejects_a_parameter_name_of_another_client_before_any_call \
  url_script_accepts_the_hyphen_variant_of_an_underscore_client \
  url_script_rejects_an_unknown_client_before_any_aws_call \
  url_script_rejects_an_empty_clients_map_before_any_aws_call \
  url_script_rejects_an_empty_or_null_password_or_address_before_any_aws_call \
  url_script_writes_the_default_scheme_url_and_prints_only_the_version \
  url_script_uses_the_given_scheme \
  url_script_fails_when_the_put_fails_and_leaves_no_file \
  driver_help_prints_usage_and_exits_0 \
  driver_rejects_a_wrong_argument_count_with_usage \
  driver_rejects_a_bad_parameter_prefix_with_usage \
  driver_rejects_an_unknown_client_before_any_aws_call \
  driver_rejects_an_empty_clients_map_before_any_aws_call \
  driver_rejects_empty_or_null_secrets_and_address_before_any_aws_call \
  driver_bootstraps_the_client_and_cleans_up \
  driver_reports_a_rejected_instance_and_still_cleans_up \
  driver_fails_when_the_command_fails_and_still_cleans_up \
  driver_times_out_after_ten_minutes_and_still_cleans_up \
  driver_warns_and_fails_when_the_cleanup_delete_fails \
  driver_fails_on_a_cancelled_command_and_still_cleans_up \
  driver_fails_on_a_timed_out_command_and_still_cleans_up \
  driver_keeps_polling_while_delayed \
  driver_fails_fast_when_the_login_expires_while_polling \
  driver_warns_even_when_interrupted_during_cleanup \
  driver_cleans_up_a_failed_put_without_a_false_warning \
  driver_deletes_a_parameter_whose_put_was_interrupted \
  server_fails_readably_without_docker \
  server_fails_readably_without_the_aws_cli \
  server_fails_on_an_empty_staged_value \
  server_streams_the_password_line_and_client_sql_into_psql; do
  run_case "$test_case"
done

echo "${case_count} cases, $((case_count - failed_cases)) passed, ${failed_cases} failed"
[[ "$failed_cases" -eq 0 ]]
