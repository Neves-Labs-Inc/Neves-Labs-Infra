#!/usr/bin/env bash
# Writes a client's app connection string to a SecureString parameter in the client's account, without ever
# showing the password: it goes through a private temporary file only.
#
# Usage: database/set-database-url.sh <client> <aws-profile> <parameter-name> [scheme]
#   <parameter-name> must start with /<client>/ (underscores in the client name may be hyphens).
#   e.g. database/set-database-url.sh tutorlink tutorlink-prod /tutorlink/prod/DATABASE_URL postgresql+psycopg
#
# The value is <scheme>://<client>:<password>@<address>:5432/<client>?sslmode=require. The scheme defaults to
# postgresql. The password goes in unencoded: random_password.client has special = false, so it needs no escaping.
#
# Prerequisites: jq, the AWS CLI with a login for <aws-profile>, and terraform with database/ applied and the client
# in its clients map. Reads terraform with the management default profile. Prints only "<name> set, version <N>".
set -euo pipefail

readonly REGION="us-east-1"
readonly EXPECTED_MIN_ARGUMENT_COUNT=3
readonly EXPECTED_MAX_ARGUMENT_COUNT=4
readonly DEFAULT_SCHEME="postgresql"
readonly SCHEME_PATTERN='^[a-z][a-z0-9+.-]*$'
readonly POSTGRES_PORT=5432

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DATABASE_ROOT="${REPO_ROOT}/database"

print_usage() {
  echo "Usage: database/set-database-url.sh <client> <aws-profile> <parameter-name> [scheme]"
  echo "Writes <scheme>://<client>:<password>@<address>:${POSTGRES_PORT}/<client>?sslmode=require to the SecureString"
  echo "parameter <parameter-name>, which must start with /<client>/ (underscores in the client may be hyphens) in the account of <aws-profile>. <scheme> defaults to ${DEFAULT_SCHEME}."
}

fail() {
  echo "set-database-url: $1" >&2
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

# Runs on every exit, so the file that held the password never outlives the run.
cleanup() {
  rm -rf "$work_dir"
}

# --- Arguments ----------------------------------------------------------------------------------------------------

if [[ $# -eq 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
  print_usage
  exit 0
fi
[[ $# -ge $EXPECTED_MIN_ARGUMENT_COUNT && $# -le $EXPECTED_MAX_ARGUMENT_COUNT ]] || usage_error
client="$1"
profile="$2"
parameter_name="$3"
scheme="${4-$DEFAULT_SCHEME}"
[[ "$scheme" =~ $SCHEME_PATTERN ]] || fail "invalid scheme '${scheme}': it must match ${SCHEME_PATTERN}"
# Ties the name to the client, so swapped arguments can't write one client's credential into another's parameter.
# Underscores in the client name may appear as hyphens (tn_cleaning -> /tn-cleaning/...).
hyphenated_client="${client//_/-}"
if [[ "$parameter_name" != "/${client}/"* && "$parameter_name" != "/${hyphenated_client}/"* ]]; then
  fail "the parameter name must start with /${client}/ or /${hyphenated_client}/, like /${hyphenated_client}/prod/DATABASE_URL"
fi

# --- Inputs from terraform, before anything touches AWS -----------------------------------------------------------

connection_limits="$(read_output client_connection_limits)" \
  || fail "could not read terraform output client_connection_limits"
if jq -e 'length == 0' <<<"$connection_limits" >/dev/null; then
  fail "the clients map in database/variables.tf is empty: add the client there and apply database/ first"
fi
if ! jq -e --arg client "$client" 'has($client)' <<<"$connection_limits" >/dev/null; then
  known_clients="$(jq -r 'keys | join(", ")' <<<"$connection_limits")"
  fail "unknown client '${client}'. Known clients: ${known_clients}"
fi

client_password="$(read_output client_passwords | jq -r --arg client "$client" '.[$client] // empty')" \
  || fail "could not read terraform output client_passwords"
if [[ -z "$client_password" ]]; then
  fail "the password for '${client}' is empty or null: check terraform output -json client_passwords"
fi

address="$(read_output address | jq -r '. // empty')" || fail "could not read terraform output address"
if [[ -z "$address" ]]; then
  fail "the database address is empty or null: check terraform output -json address"
fi

# --- Write the parameter ------------------------------------------------------------------------------------------

umask 077
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/set-database-url.XXXXXX")"
trap cleanup EXIT
# Without this, Ctrl-C would skip the EXIT trap in some shells and leave the file behind.
trap 'exit 130' INT TERM HUP
input_file="${work_dir}/parameter.json"

# The value comes in on stdin, so the password never shows up in jq's arguments.
printf '%s://%s:%s@%s:%s/%s?sslmode=require' "$scheme" "$client" "$client_password" "$address" "$POSTGRES_PORT" "$client" \
  | jq -Rs --arg name "$parameter_name" '{Name: $name, Type: "SecureString", Overwrite: true, Value: .}' >"$input_file"

version="$(aws ssm put-parameter --profile "$profile" --region "$REGION" --cli-input-json "file://${input_file}" \
  --query Version --output text)" \
  || fail "could not write ${parameter_name} in profile ${profile}: refresh your login and try again"

echo "${parameter_name} set, version ${version}"
