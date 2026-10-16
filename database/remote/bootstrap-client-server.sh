#!/usr/bin/env bash
# Host side of database/bootstrap-client.sh: runs on a host in the client's account, sent there through Systems
# Manager Run Command next to a copy of database/sql/client.sql, and runs that SQL against neves-labs-pg as
# neveslabs_admin from a postgres:17-alpine container.
#
# Usage: bash bootstrap-client-server.sh <address> <client> <connection_limit> <admin_param_name> <client_param_name>
#
# The two passwords come from SecureString parameters the driver staged, never from arguments. They live only in
# this process's environment and the containers': never echoed, never written to disk. client.sql receives the
# client password through a \getenv line streamed in front of it.
set -euo pipefail

readonly REGION="us-east-1"
# Pinned by digest. To bump: docker pull postgres:17-alpine, then
# docker image inspect postgres:17-alpine --format '{{index .RepoDigests 0}}' and paste the sha256 here.
readonly POSTGRES_IMAGE="postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"
readonly EXPECTED_ARGUMENT_COUNT=5

fail() {
  echo "bootstrap (server): $1" >&2
  exit 1
}

if [[ $# -ne $EXPECTED_ARGUMENT_COUNT ]]; then
  fail "usage: bootstrap-client-server.sh <address> <client> <connection_limit> <admin_param_name> <client_param_name>"
fi
address="$1"
client="$2"
connection_limit="$3"
admin_parameter="$4"
client_parameter="$5"

command -v docker >/dev/null || fail "docker is not installed"
command -v aws >/dev/null || fail "the AWS CLI is not installed"

# The driver decodes client.sql next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CLIENT_SQL="${SCRIPT_DIR}/client.sql"
[[ -f "$CLIENT_SQL" ]] || fail "client.sql is missing next to the script"

read_parameter() {
  aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption --query Parameter.Value --output text
}

if ! PGPASSWORD="$(read_parameter "$admin_parameter")"; then
  fail "could not read ${admin_parameter}: check the instance role can read and decrypt it"
fi
if ! CLIENT_PASSWORD="$(read_parameter "$client_parameter")"; then
  fail "could not read ${client_parameter}: check the instance role can read and decrypt it"
fi
[[ -n "$PGPASSWORD" ]] || fail "the staged value of ${admin_parameter} is empty"
[[ -n "$CLIENT_PASSWORD" ]] || fail "the staged value of ${client_parameter} is empty"
export PGPASSWORD CLIENT_PASSWORD

conn="host=${address} port=5432 dbname=postgres user=neveslabs_admin sslmode=require"

# -X so a ~/.psqlrc in the image can't change the run or echo the password. VERBOSITY=terse because a failing
# CREATE or ALTER ROLE would otherwise print a LINE excerpt of the statement, password included, into the Run
# Command output. neves-labs-pg keeps log_statement = none, but RDS may still log a failed statement under
# log_min_error_statement (default error); that server setting is outside this script's reach.
{
  printf '%s\n' '\getenv client_password CLIENT_PASSWORD'
  cat "$CLIENT_SQL"
} | docker run --rm -i --network host -e PGPASSWORD -e CLIENT_PASSWORD "$POSTGRES_IMAGE" \
  psql -X "$conn" -v VERBOSITY=terse -v client="$client" -v connection_limit="$connection_limit" -f -

docker run --rm --network host -e PGPASSWORD "$POSTGRES_IMAGE" \
  psql -X "$conn" -c "\\du ${client}" -c "\\l ${client}"
