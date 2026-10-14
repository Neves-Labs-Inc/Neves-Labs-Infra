#!/usr/bin/env bash
# Gives one client its own login role and database on neves-labs-pg, by running database/sql/client.sql as
# neveslabs_admin with the client's password and connection limit from terraform output.
#
# Usage: database/bootstrap-client.sh <client>
#
# Prerequisites:
#   - psql 17 (and pg_isready, which ships with it)
#   - terraform, with database/ applied and the client in its clients map
#   - jq
#   - the port-forward to neves-labs-pg open on localhost:15432 (database/RUNBOOK.md, step 1)
#
# psql runs with -X so a ~/.psqlrc (AUTOCOMMIT off, ECHO queries) can't break the run or print the password.
# Secrets stay in unexported shell variables and reach psql only through its own command line and environment.
set -euo pipefail

readonly LOCAL_PORT=15432
readonly ADMIN_CONNECTION="host=localhost port=${LOCAL_PORT} dbname=postgres user=neveslabs_admin sslmode=require"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DATABASE_ROOT="${REPO_ROOT}/database"
readonly CLIENT_SQL="${DATABASE_ROOT}/sql/client.sql"

print_usage() {
  echo "Usage: database/bootstrap-client.sh <client>"
  echo "Creates or converges the client's login role and database on neves-labs-pg."
}

fail() {
  echo "bootstrap-client: $1" >&2
  exit 1
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  print_usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  print_usage >&2
  exit 1
fi
client="$1"

connection_limits="$(terraform -chdir="$DATABASE_ROOT" output -json client_connection_limits)"
if jq -e 'length == 0' <<<"$connection_limits" >/dev/null; then
  fail "the clients map in database/variables.tf is empty: add the client there and apply database/ first"
fi
if ! jq -e --arg client "$client" 'has($client)' <<<"$connection_limits" >/dev/null; then
  known_clients="$(jq -r 'keys | join(", ")' <<<"$connection_limits")"
  fail "unknown client '${client}'. Known clients: ${known_clients}"
fi
connection_limit="$(jq -r --arg client "$client" '.[$client]' <<<"$connection_limits")"

client_password="$(terraform -chdir="$DATABASE_ROOT" output -json client_passwords \
  | jq -r --arg client "$client" '.[$client] // empty')"
if [[ -z "$client_password" ]]; then
  fail "the password for '${client}' is empty or null: check terraform output -json client_passwords"
fi

if ! pg_isready -q -h localhost -p "$LOCAL_PORT"; then
  fail "nothing is listening on localhost:${LOCAL_PORT}. Open the port-forward from database/RUNBOOK.md step 1 first."
fi

admin_password="$(terraform -chdir="$DATABASE_ROOT" output -raw admin_password)"

PGPASSWORD="$admin_password" psql -X "$ADMIN_CONNECTION" \
  -v client="$client" \
  -v client_password="$client_password" \
  -v connection_limit="$connection_limit" \
  -f "$CLIENT_SQL"

PGPASSWORD="$admin_password" psql -X "$ADMIN_CONNECTION" -c "\\du ${client}" -c "\\l ${client}"
