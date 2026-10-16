#!/usr/bin/env bash
# Logging wrapper around the real jq (STUB_REAL_JQ), so the leak checks also cover jq's argv.
# Installed on PATH as `jq`.
echo "jq $*" >>"${STUB_STATE_DIR:?STUB_STATE_DIR must be set}/calls.log"
exec "${STUB_REAL_JQ:?STUB_REAL_JQ must be set}" "$@"
