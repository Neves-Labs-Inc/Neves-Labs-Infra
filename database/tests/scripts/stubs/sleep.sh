#!/usr/bin/env bash
# Fake `sleep` for the bootstrap stub tests: polling runs instantly. Installed on PATH as `sleep`.
echo "sleep $*" >>"${STUB_STATE_DIR:?STUB_STATE_DIR must be set}/calls.log"
