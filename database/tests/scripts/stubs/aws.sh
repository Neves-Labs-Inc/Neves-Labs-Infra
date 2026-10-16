#!/usr/bin/env bash
# Fake `aws` for the bootstrap stub tests. Installed on PATH as `aws`; never talks to AWS.
#
# It plays both sides of Systems Manager:
#   - a parameter store kept as files under $STUB_STATE_DIR/parameters (put-parameter, get-parameter,
#     delete-parameters);
#   - Run Command: send-command runs the sent shell command locally with `sh`, and get-command-invocation reports
#     its outcome.
#
# Every call appends its argv to $STUB_STATE_DIR/calls.log. Each file:// input is copied to
# $STUB_STATE_DIR/captured/<operation>-<n>.json.
#
# Flags:
#   STUB_AWS_FAIL_PUT=1                put-parameter fails, without storing anything
#   STUB_AWS_PUT_VERSION=<n>           the version put-parameter reports with --query Version (default 1)
#   STUB_AWS_INTERRUPT_ON_PUT=1        put-parameter stores the value, then sends SIGINT to its caller (a Ctrl-C)
#   STUB_AWS_FAIL_SEND_COMMAND=1       send-command fails
#   STUB_AWS_FAIL_DELETE=1             delete-parameters fails
#   STUB_AWS_INTERRUPT_ON_DELETE=1     delete-parameters sends SIGINT to its caller first (a Ctrl-C during cleanup)
#   STUB_AWS_POLL_ERRORS=<n>           the first n get-command-invocation calls fail...
#   STUB_AWS_POLL_ERROR=<code>         ...with this error code (default InvocationDoesNotExist)
#   STUB_AWS_PENDING_POLLS=<n>         the next n get-command-invocation calls report a pending status...
#   STUB_AWS_PENDING_STATUS=<status>   ...this one (default InProgress)
#   STUB_AWS_FINAL_STATUS=<status>     overrides the final status the command actually reached
set -euo pipefail

readonly STATE_DIR="${STUB_STATE_DIR:?STUB_STATE_DIR must be set}"
readonly PARAMETERS_DIR="${STATE_DIR}/parameters"
readonly CAPTURED_DIR="${STATE_DIR}/captured"
readonly INVOCATION_DIR="${STATE_DIR}/invocation"
readonly COMMAND_ID="stub-command-id"

mkdir -p "$PARAMETERS_DIR" "$CAPTURED_DIR" "$INVOCATION_DIR"
echo "aws $*" >>"${STATE_DIR}/calls.log"

service="$1"
operation="$2"
shift 2

input_file=""
parameters_file=""
parameter_name=""
query=""
names=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli-input-json) input_file="${2#file://}"; shift 2 ;;
    --parameters) parameters_file="${2#file://}"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    --name) parameter_name="$2"; shift 2 ;;
    --names)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        names+=("$1")
        shift
      done
      ;;
    *) shift ;;
  esac
done

# Parameter names hold slashes, so they're flattened into one file name.
parameter_path() {
  echo "${PARAMETERS_DIR}/${1//\//__}"
}

capture() {
  local count
  count="$(find "$CAPTURED_DIR" -name "${operation}-*" | wc -l | tr -d ' ')"
  cp "$1" "${CAPTURED_DIR}/${operation}-$((count + 1)).json"
}

# Counts down a numeric flag in a state file, so it survives across calls. Succeeds while the count lasts.
take_one() {
  local counter_file="${STATE_DIR}/${1}.left" left
  if [[ ! -f "$counter_file" ]]; then
    echo "$2" >"$counter_file"
  fi
  left="$(cat "$counter_file")"
  [[ "$left" -gt 0 ]] || return 1
  echo $((left - 1)) >"$counter_file"
}

json_array() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -sc .
  fi
}

if [[ "$service" != "ssm" ]]; then
  echo "stub aws: unsupported service ${service}" >&2
  exit 2
fi

case "$operation" in
  put-parameter)
    capture "$input_file"
    if [[ -n "${STUB_AWS_FAIL_PUT:-}" ]]; then
      echo "An error occurred (ExpiredTokenException) when calling the PutParameter operation" >&2
      exit 254
    fi
    name="$(jq -r '.Name' "$input_file")"
    jq -j '.Value' "$input_file" >"$(parameter_path "$name")"
    if [[ -n "${STUB_AWS_INTERRUPT_ON_PUT:-}" ]]; then
      kill -INT "$PPID"
    fi
    if [[ "$query" == "Version" ]]; then
      echo "${STUB_AWS_PUT_VERSION:-1}"
    else
      echo '{"Version": 1, "Tier": "Standard"}'
    fi
    ;;
  get-parameter)
    stored="$(parameter_path "$parameter_name")"
    if [[ ! -f "$stored" ]]; then
      echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2
      exit 254
    fi
    cat "$stored"
    echo
    ;;
  delete-parameters)
    if [[ -n "${STUB_AWS_INTERRUPT_ON_DELETE:-}" ]]; then
      kill -INT "$PPID"
    fi
    if [[ -n "${STUB_AWS_FAIL_DELETE:-}" ]]; then
      echo "An error occurred (ExpiredTokenException) when calling the DeleteParameters operation" >&2
      exit 254
    fi
    # Like AWS: names that don't exist are listed as InvalidParameters, and the call still succeeds.
    deleted=()
    invalid=()
    for name in "${names[@]}"; do
      if [[ -f "$(parameter_path "$name")" ]]; then
        rm -f "$(parameter_path "$name")"
        deleted+=("$name")
      else
        invalid+=("$name")
      fi
    done
    jq -n --argjson deleted "$(json_array ${deleted[@]+"${deleted[@]}"})" \
      --argjson invalid "$(json_array ${invalid[@]+"${invalid[@]}"})" \
      '{DeletedParameters: $deleted, InvalidParameters: $invalid}'
    ;;
  send-command)
    capture "$parameters_file"
    if [[ -n "${STUB_AWS_FAIL_SEND_COMMAND:-}" ]]; then
      echo "An error occurred (InvalidInstanceId) when calling the SendCommand operation" >&2
      exit 254
    fi
    command_text="$(jq -r '.commands[0]' "$parameters_file")"
    status="Success"
    sh -c "$command_text" </dev/null >"${INVOCATION_DIR}/stdout" 2>"${INVOCATION_DIR}/stderr" || status="Failed"
    echo "$status" >"${INVOCATION_DIR}/status"
    echo "$COMMAND_ID"
    ;;
  get-command-invocation)
    if take_one STUB_AWS_POLL_ERRORS "${STUB_AWS_POLL_ERRORS:-0}"; then
      echo "An error occurred (${STUB_AWS_POLL_ERROR:-InvocationDoesNotExist}) when calling the GetCommandInvocation operation" >&2
      exit 254
    fi
    status="${STUB_AWS_FINAL_STATUS:-$(cat "${INVOCATION_DIR}/status")}"
    if take_one STUB_AWS_PENDING_POLLS "${STUB_AWS_PENDING_POLLS:-0}"; then
      status="${STUB_AWS_PENDING_STATUS:-InProgress}"
    fi
    jq -n \
      --arg status "$status" \
      --arg stdout "$(cat "${INVOCATION_DIR}/stdout")" \
      --arg stderr "$(cat "${INVOCATION_DIR}/stderr")" \
      '{Status: $status, StandardOutputContent: $stdout, StandardErrorContent: $stderr}'
    ;;
  *)
    echo "stub aws: unsupported operation ${operation}" >&2
    exit 2
    ;;
esac
