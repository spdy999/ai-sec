#!/usr/bin/env bash
#
# Run a shell script on the jump host and wait for it, because there is no other
# way in. The cluster's API server is private, the nodes are in private subnets,
# and no GitHub runner has a route to either. The jump host does, and it already
# holds an EKS access entry, so Session Manager is the path that needs no
# inbound rule, no public endpoint and no long-lived key.
#
# Usage: ssm-run.sh <instance-id> <script-file>
#
# Exits non-zero if the command fails on the host. The host's stdout and stderr
# are printed here, because a deploy whose output stays on the instance is a
# deploy nobody can review.
set -euo pipefail

instance="${1:?instance id required}"
script_file="${2:?script file required}"

# --parameters takes the CLI's shorthand syntax, which splits on commas and
# does not survive embedded newlines: the script arrives as one mangled line
# and bash fails on an unterminated quote. A JSON file avoids the shorthand
# parser entirely, and is the only form that carries a multi-line script
# intact.
params="$(mktemp)"
trap 'rm -f "${params}"' EXIT
jq -Rs '{commands: [.]}' <"${script_file}" >"${params}"

command_id="$(aws ssm send-command \
  --instance-ids "${instance}" \
  --document-name AWS-RunShellScript \
  --comment "github ${GITHUB_RUN_ID:-manual}" \
  --parameters "file://${params}" \
  --query 'Command.CommandId' --output text)"

echo "ssm command ${command_id} on ${instance}"

# send-command is asynchronous and the invocation does not exist for a moment
# after it returns; waiting on it immediately fails with InvocationDoesNotExist.
sleep 5

status="Pending"
while [ "${status}" = "Pending" ] || [ "${status}" = "InProgress" ] || [ "${status}" = "Delayed" ]; do
  sleep 10
  status="$(aws ssm get-command-invocation \
    --command-id "${command_id}" --instance-id "${instance}" \
    --query Status --output text)"
done

aws ssm get-command-invocation \
  --command-id "${command_id}" --instance-id "${instance}" \
  --query StandardOutputContent --output text

stderr="$(aws ssm get-command-invocation \
  --command-id "${command_id}" --instance-id "${instance}" \
  --query StandardErrorContent --output text)"

if [ -n "${stderr}" ] && [ "${stderr}" != "None" ]; then
  echo "--- stderr ---" >&2
  echo "${stderr}" >&2
fi

echo "ssm command ${status}"
[ "${status}" = "Success" ]
