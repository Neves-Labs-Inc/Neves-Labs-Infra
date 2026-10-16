#!/usr/bin/env bash
# Gives one client its own login role and database on neves-labs-pg. Runs database/sql/client.sql as
# neveslabs_admin on a host in the client's account through Systems Manager Run Command, so nothing on this
# machine connects to the database.
#
# Usage: database/bootstrap-client.sh <client> <aws-profile> <instance-id> <parameter-prefix>
#   e.g. database/bootstrap-client.sh acme acme-prod i-0123456789abcdef0 /acme/prod
#
# How it works:
#   1. Reads the address, the admin password, and the client's password and connection limit from terraform output
#      (management default profile).
#   2. Stages both passwords as temporary SecureString parameters <prefix>-bootstrap/NEVESLABS_ADMIN_PASSWORD and
#      <prefix>-bootstrap/CLIENT_DB_PASSWORD in the client account.
#   3. Sends database/remote/bootstrap-client-server.sh and client.sql to the host, which reads the parameters and
#      runs psql from a postgres:17-alpine container. Prints its output, including \du and \l for the client.
#   4. Deletes the staged parameters on any exit, and warns loudly if that fails.
#
# Prerequisites:
#   - jq, the AWS CLI, and a login for <aws-profile>
#   - terraform, with database/ applied and the client in its clients map
#   - <instance-id>: a Systems Manager managed node in the client account, with Docker and the AWS CLI,
#     sitting in the client's app subnet (5432 on neves-labs-pg only opens from app_subnet_cidr)
#   - its instance role can read <prefix>* and decrypt with the key of those parameters
#   - an active peering between the client network and the neves-labs-pg network
#
# No password ever appears in a process argument list, the Run Command parameters, or the output.
#
# The neves-labs-pg admin password sits in the client account for the length of the run. That is acceptable only
# because clients have no access to their AWS accounts: Franklin manages them.
set -euo pipefail

readonly REGION="us-east-1"
readonly POLL_INTERVAL_SECONDS=5
readonly POLL_TIMEOUT_SECONDS=600
readonly MAX_POLLS=$((POLL_TIMEOUT_SECONDS / POLL_INTERVAL_SECONDS))
readonly EXPECTED_ARGUMENT_COUNT=4
# Path segments of letters, digits, _ . and -, so the parameter names are safe to print and paste.
readonly PREFIX_PATTERN='^(/[A-Za-z0-9_.-]+)+$'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DATABASE_ROOT="${REPO_ROOT}/database"
readonly CLIENT_SQL="${DATABASE_ROOT}/sql/client.sql"
readonly SERVER_SCRIPT="${DATABASE_ROOT}/remote/bootstrap-client-server.sh"

print_usage() {
  echo "Usage: database/bootstrap-client.sh <client> <aws-profile> <instance-id> <parameter-prefix>"
  echo "Creates or converges the client's login role and database on neves-labs-pg, from a host in the client's"
  echo "account through Systems Manager Run Command. <parameter-prefix> is a path such as /acme/prod: it starts"
  echo "with /, doesn't end with /, and its segments use only letters, digits, _ . and -."
}

fail() {
  echo "bootstrap-client: $1" >&2
  exit 1
}

usage_error() {
  print_usage >&2
  exit 1
}

# Reads one terraform output as JSON, with the management default profile.
read_output() {
  env -u AWS_PROFILE terraform -chdir="$DATABASE_ROOT" output -json "$1"
}

# Wraps a value in single quotes for the host's sh. Only non-secret values pass through here.
# The replacement sits in a variable because bash 3.2 mangles quotes written inline in ${var//pattern/replacement}.
quote_for_sh() {
  local quote="'" escaped_quote="'\\''"
  printf "'%s'" "${1//$quote/$escaped_quote}"
}

aws_ssm() {
  local operation="$1"
  shift
  aws ssm "$operation" --profile "$profile" --region "$REGION" "$@"
}

# The password comes in on stdin, so it never shows up in jq's arguments.
write_parameter_input() {
  local name="$1" file="$2"
  jq -Rs --arg name "$name" '{Name: $name, Type: "SecureString", Overwrite: true, Value: .}' >"$file"
}

# Records the name before the put: an interrupted or failed put may still have landed, so cleanup deletes it.
stage_parameter() {
  local name="$1" password="$2" input_file="${work_dir}/parameter.json"
  staged_parameters+=("$name")
  printf '%s' "$password" | write_parameter_input "$name" "$input_file"
  aws_ssm put-parameter --cli-input-json "file://${input_file}" >/dev/null
  rm -f "$input_file"
}

# Builds the one shell command the host runs: decode both files into a root-only directory, run, clean up.
build_remote_command() {
  local script_base64 sql_base64 arguments="" argument
  script_base64="$(base64 <"$SERVER_SCRIPT" | tr -d '\n')"
  sql_base64="$(base64 <"$CLIENT_SQL" | tr -d '\n')"
  for argument in "$address" "$client" "$connection_limit" "$admin_parameter" "$client_parameter"; do
    arguments+=" $(quote_for_sh "$argument")"
  done
  printf '%s' "dir=\"\$(mktemp -d)\" || exit 1; " \
    "echo ${script_base64} | base64 -d > \"\$dir/bootstrap-client-server.sh\" && " \
    "echo ${sql_base64} | base64 -d > \"\$dir/client.sql\" && " \
    "bash \"\$dir/bootstrap-client-server.sh\"${arguments}; " \
    "rc=\$?; rm -rf \"\$dir\"; exit \$rc"
}

# Writes the invocation JSON to $2 once it leaves Pending, InProgress or Delayed. Fails on the timeout, and at
# once on any error other than the invocation not being visible yet (an expired login, for example).
wait_for_invocation() {
  local command_id="$1" invocation_file="$2" error_file="${work_dir}/poll-error.txt" poll status
  for ((poll = 1; poll <= MAX_POLLS; poll++)); do
    sleep "$POLL_INTERVAL_SECONDS"
    if ! aws_ssm get-command-invocation --instance-id "$instance_id" --command-id "$command_id" \
      --output json >"$invocation_file" 2>"$error_file"; then
      # Right after send-command the invocation may not be visible yet: keep waiting.
      grep -q InvocationDoesNotExist "$error_file" && continue
      cat "$error_file" >&2
      fail "could not check command ${command_id} on ${instance_id}: refresh your login for profile ${profile} and check the command's status in the Systems Manager console"
    fi
    status="$(jq -r '.Status' "$invocation_file")"
    case "$status" in
      Pending | InProgress | Delayed) ;;
      *) return 0 ;;
    esac
  done
  fail "timed out after ${POLL_TIMEOUT_SECONDS} seconds waiting for command ${command_id} on ${instance_id}"
}

# Runs on every exit: temporary files go, staged parameters go, and a failed delete is loud and fails the run.
# delete-parameters succeeds for names that don't exist (it lists them as InvalidParameters), so a put that never
# landed causes no warning; only a failed delete call does.
cleanup() {
  local exit_code=$? name
  # A second Ctrl-C must not cut the delete or the warning short.
  trap '' INT TERM HUP
  rm -rf "$work_dir"
  if [[ ${#staged_parameters[@]} -gt 0 ]] \
    && ! aws_ssm delete-parameters --names "${staged_parameters[@]}" >/dev/null; then
    {
      echo "bootstrap-client: WARNING: could not delete the staged password parameters"
      for name in "${staged_parameters[@]}"; do
        echo "bootstrap-client:   ${name}"
      done
      echo "bootstrap-client: they hold neves-labs-pg passwords. Delete them now with:"
      printf 'aws ssm delete-parameters --profile %q --region %q --names' "$profile" "$REGION"
      printf ' %q' "${staged_parameters[@]}"
      printf '\n'
    } >&2
    [[ "$exit_code" -ne 0 ]] || exit_code=1
  fi
  exit "$exit_code"
}

# --- Arguments ----------------------------------------------------------------------------------------------------

if [[ $# -eq 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
  print_usage
  exit 0
fi
[[ $# -eq $EXPECTED_ARGUMENT_COUNT ]] || usage_error
client="$1"
profile="$2"
instance_id="$3"
prefix="$4"
[[ "$prefix" =~ $PREFIX_PATTERN ]] || usage_error

readonly admin_parameter="${prefix}-bootstrap/NEVESLABS_ADMIN_PASSWORD"
readonly client_parameter="${prefix}-bootstrap/CLIENT_DB_PASSWORD"

# --- 1. Inputs from terraform, before anything touches AWS --------------------------------------------------------

connection_limits="$(read_output client_connection_limits)" \
  || fail "could not read terraform output client_connection_limits"
if jq -e 'length == 0' <<<"$connection_limits" >/dev/null; then
  fail "the clients map in database/variables.tf is empty: add the client there and apply database/ first"
fi
if ! jq -e --arg client "$client" 'has($client)' <<<"$connection_limits" >/dev/null; then
  known_clients="$(jq -r 'keys | join(", ")' <<<"$connection_limits")"
  fail "unknown client '${client}'. Known clients: ${known_clients}"
fi
connection_limit="$(jq -r --arg client "$client" '.[$client]' <<<"$connection_limits")"

client_password="$(read_output client_passwords | jq -r --arg client "$client" '.[$client] // empty')" \
  || fail "could not read terraform output client_passwords"
if [[ -z "$client_password" ]]; then
  fail "the password for '${client}' is empty or null: check terraform output -json client_passwords"
fi

admin_password="$(read_output admin_password | jq -r '. // empty')" \
  || fail "could not read terraform output admin_password"
if [[ -z "$admin_password" ]]; then
  fail "the admin password is empty or null: check terraform output -json admin_password"
fi

address="$(read_output address | jq -r '. // empty')" || fail "could not read terraform output address"
if [[ -z "$address" ]]; then
  fail "the database address is empty or null: check terraform output -json address"
fi

# --- 2. Cleanup trap, before the first stage ----------------------------------------------------------------------

umask 077
staged_parameters=()
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-client.XXXXXX")"
trap cleanup EXIT
# Without this, Ctrl-C would skip the EXIT trap in some shells and leave the parameters behind.
trap 'exit 130' INT TERM HUP

# --- 3. Stage the passwords ---------------------------------------------------------------------------------------

stage_parameter "$admin_parameter" "$admin_password"
stage_parameter "$client_parameter" "$client_password"
echo "[${client}] staged ${admin_parameter} and ${client_parameter} in ${profile}"

# --- 4. Send the server script ------------------------------------------------------------------------------------

command_parameters="${work_dir}/command.json"
build_remote_command | jq -Rs '{commands: [.], executionTimeout: ["600"]}' >"$command_parameters"
if ! command_id="$(aws_ssm send-command --instance-ids "$instance_id" --document-name AWS-RunShellScript \
  --comment "neves-labs bootstrap: ${client}" --parameters "file://${command_parameters}" \
  --query Command.CommandId --output text)"; then
  fail "Run Command rejected instance ${instance_id} in profile ${profile}: check that it is an online Systems Manager managed node and that the login hasn't expired"
fi
rm -f "$command_parameters"
echo "[${client}] command ${command_id} sent to ${instance_id}, waiting..."

# --- 5. Wait and report -------------------------------------------------------------------------------------------

invocation_file="${work_dir}/invocation.json"
wait_for_invocation "$command_id" "$invocation_file"
status="$(jq -r '.Status' "$invocation_file")"
jq -r '.StandardOutputContent' "$invocation_file"
jq -r '.StandardErrorContent // empty' "$invocation_file" >&2
echo "[${client}] bootstrap: ${status}"
[[ "$status" == "Success" ]]
