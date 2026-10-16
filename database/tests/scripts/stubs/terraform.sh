#!/usr/bin/env bash
# Fake `terraform` for the bootstrap stub tests. Installed on PATH as `terraform`.
#
# Answers `terraform -chdir=... output -json <name>` from STUB_TF_<NAME> (the output's JSON); an unset variable
# fails like a missing output. Logs argv, and whether AWS_PROFILE was set, to $STUB_STATE_DIR/calls.log.
set -euo pipefail

echo "terraform AWS_PROFILE=${AWS_PROFILE-<unset>} $*" >>"${STUB_STATE_DIR:?STUB_STATE_DIR must be set}/calls.log"

output_name="${*: -1}"
variable_name="STUB_TF_$(echo "$output_name" | tr '[:lower:]' '[:upper:]')"
if [[ -z "${!variable_name+set}" ]]; then
  echo "Error: Output \"${output_name}\" not found" >&2
  exit 1
fi
echo "${!variable_name}"
