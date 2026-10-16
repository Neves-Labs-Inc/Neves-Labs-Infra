#!/usr/bin/env bash
# Fake `docker` for the bootstrap stub tests. Installed on PATH as `docker`.
#
# Logs argv to $STUB_STATE_DIR/calls.log. For `docker run -i`, copies stdin to $STUB_STATE_DIR/captured/docker-stdin-<n>
# and the PGPASSWORD and CLIENT_PASSWORD it was given to docker-env-<n> files, so tests can check what psql would
# have received. A `\du` call prints a fake listing. STUB_DOCKER_FAIL=1 makes every call fail.
set -euo pipefail

readonly STATE_DIR="${STUB_STATE_DIR:?STUB_STATE_DIR must be set}"
readonly CAPTURED_DIR="${STATE_DIR}/captured"

mkdir -p "$CAPTURED_DIR"
echo "docker $*" >>"${STATE_DIR}/calls.log"

if [[ -n "${STUB_DOCKER_FAIL:-}" ]]; then
  echo "psql: error: connection to server failed" >&2
  exit 2
fi

is_interactive=false
listing=""
for argument in "$@"; do
  case "$argument" in
    -i) is_interactive=true ;;
    '\du '* | '\l '*) listing+="stub listing for ${argument}"$'\n' ;;
  esac
done

count="$(find "$CAPTURED_DIR" -name 'docker-stdin-*' | wc -l | tr -d ' ')"
if [[ "$is_interactive" == true ]]; then
  cat >"${CAPTURED_DIR}/docker-stdin-$((count + 1))"
fi
printf '%s' "${PGPASSWORD-}" >"${CAPTURED_DIR}/docker-env-PGPASSWORD-$((count + 1))"
printf '%s' "${CLIENT_PASSWORD-}" >"${CAPTURED_DIR}/docker-env-CLIENT_PASSWORD-$((count + 1))"
printf '%s' "$listing"
