#!/usr/bin/env bash
#
# Presentation layer over conftest.
#
# conftest reports one "test" per rule per document, so a directory of nine
# manifests against seventy rules reads as "630 tests" — a number that means
# nothing to anyone watching. These wrappers report what the gate actually
# decided: how many rules exist, how many documents they read, and what failed.
#
# Exit codes are conftest's, not softened. `fail` inverts them on purpose: the
# insecure fixtures must be rejected, so a clean run there is a failure.
set -euo pipefail

POLICY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# How many failures to print before collapsing the rest into a count. 0 prints
# every one. The demo sets this low; CI leaves it unset so the log is complete.
SHOW="${SHOW:-0}"

rule_count() {
	grep -ch '^deny contains' "$POLICY_DIR"/*.rego | awk '{total += $1} END {print total}'
}

# conftest exits non-zero on failures, which is the signal we want to inspect
# rather than abort on.
results() {
	conftest test --policy "$POLICY_DIR" --all-namespaces -o json "$@" 2>/dev/null || true
}

messages() {
	jq -r '.[].failures[]?.msg' <<<"$1" | sort
}

# --all-namespaces returns one result object per namespace, not per file, so
# count distinct filenames instead of array entries.
document_count() {
	jq -r '[.[].filename] | unique | length' <<<"$1"
}

usage() {
	echo "usage: gate.sh {pass|fail} <path> <label>" >&2
	exit 64
}

[ $# -eq 3 ] || usage
mode="$1"
target="$2"
label="$3"

json="$(results "$target")"
msgs="$(messages "$json")"
docs="$(document_count "$json")"
rules="$(rule_count)"
failures=0
[ -n "$msgs" ] && failures="$(wc -l <<<"$msgs" | tr -d ' ')"

case "$mode" in
pass)
	if [ "$failures" -gt 0 ]; then
		echo "$msgs" | sed 's/^/  FAIL /'
		echo ""
		echo "$label: $failures rule violations — the gate rejected a secure layer"
		exit 1
	fi
	noun="documents"
	[ "$docs" -eq 1 ] && noun="document"
	echo "$label: $rules rules against $docs $noun, no violations"
	;;

fail)
	if [ "$failures" -eq 0 ]; then
		echo "NEGATIVE TEST FAILED: $label was accepted by the policy gate"
		exit 1
	fi

	if [ "$SHOW" -gt 0 ] && [ "$failures" -gt "$SHOW" ]; then
		head -n "$SHOW" <<<"$msgs" | sed 's/^/  /'
		echo "  ... and $((failures - SHOW)) more"
	else
		sed 's/^/  /' <<<"$msgs"
	fi

	echo ""
	echo "$label: $failures violations found and refused"
	;;

*) usage ;;
esac
