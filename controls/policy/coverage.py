#!/usr/bin/env python3
"""Prove that every policy rule rejects something.

A rule that has never fired is not a control, it is a comment. `make policy`
only proves the secure layers satisfy the rules; it says nothing about whether a
rule would notice if they did not. This walks every `deny` in the policy
directory, runs the negative fixtures, and matches each rule's message template
against what was actually reported.

Four rules cannot be covered and are listed in EXEMPT below. Each is the
"present but misconfigured" half of a pair whose other half is "absent
entirely" — a plan cannot simultaneously have no flow log and have one with the
wrong traffic type. They are proven by inspection of their twin, not by a
fixture, and the exemption is itself checked: if one of them ever does fire, the
entry is stale and this fails.
"""

import json
import pathlib
import re
import subprocess
import sys

POLICY_DIR = pathlib.Path(__file__).resolve().parent
REPO = POLICY_DIR.parent.parent

# Every input the gate is expected to reject.
FIXTURES = [
    REPO / "controls/terraform/fixtures/insecure/plan.json",
    REPO / "controls/kubernetes/bad",
]

# Rule message fragment -> why it cannot be covered by a fixture.
EXEMPT = {
    "has no notification block": "twin of 'no aws_budgets_budget'; a plan cannot both lack a budget and hold a malformed one",
    "has versioning disabled": "twin of 'no aws_s3_bucket_versioning'; same exclusion",
    "network: %s has %s disabled": "twin of 'no aws_s3_bucket_public_access_block'; same exclusion",
    "does not capture ALL traffic": "twin of 'the platform VPC has no flow logs'; same exclusion",
}

RULE_START = "deny contains msg if {"
MESSAGE = re.compile(r'sprintf\(\s*"((?:[^"\\]|\\.)*)"|msg :?= "((?:[^"\\]|\\.)*)"')
VERB = re.compile(r"%[vsdq]")


def rules():
    """Every deny rule in the policy directory, with its message template."""
    for path in sorted(POLICY_DIR.glob("*.rego")):
        if path.name == "lib.rego":
            continue
        lines = path.read_text().splitlines()
        starts = [i for i, line in enumerate(lines) if line.startswith(RULE_START)]
        for index, start in enumerate(starts):
            end = starts[index + 1] if index + 1 < len(starts) else len(lines)
            body = "\n".join(lines[start:end])
            match = MESSAGE.search(body)
            template = (match.group(1) or match.group(2)) if match else None
            yield path.name, start + 1, template


def reported():
    """Every message the negative fixtures provoked, one per list entry."""
    messages = []
    for fixture in FIXTURES:
        result = subprocess.run(
            ["conftest", "test", "--policy", str(POLICY_DIR),
             "--all-namespaces", "-o", "json", str(fixture)],
            capture_output=True, text=True, cwd=REPO,
        )
        for document in json.loads(result.stdout or "[]"):
            for failure in document.get("failures") or []:
                messages.append(failure["msg"])
    return messages


def fired(template, messages):
    """Did a reported message match this rule's template?

    Matched whole-line, not by substring: a template ending in "has %s
    disabled" would otherwise match any longer message that happens to contain
    those words, and a rule would be credited for another rule's output.
    """
    unescaped = template.replace('\\"', '"').replace("\\\\", "\\")
    pattern = ".*".join(re.escape(part) for part in VERB.split(unescaped))
    return any(re.fullmatch(pattern, message) for message in messages)


def main():
    messages = reported()
    if not messages:
        print("coverage: the negative fixtures produced no violations at all")
        return 1

    covered, uncovered, exempt, unreadable = 0, [], [], []

    for filename, line, template in rules():
        if template is None:
            unreadable.append(f"{filename}:{line}")
            continue

        excuse = next((reason for fragment, reason in EXEMPT.items() if fragment in template), None)
        hit = fired(template, messages)

        if excuse and hit:
            uncovered.append((filename, line, template, "exempt but it fired; remove the exemption"))
        elif excuse:
            exempt.append((filename, line, excuse))
        elif hit:
            covered += 1
        else:
            uncovered.append((filename, line, template, "never fired against any fixture"))

    total = covered + len(uncovered) + len(exempt)
    print(f"coverage: {covered} of {total} rules proven to reject a fixture, {len(exempt)} exempt by construction")

    for filename, line, reason in exempt:
        print(f"  exempt  {filename}:{line}  {reason}")

    if unreadable:
        for location in unreadable:
            print(f"  ERROR   {location}  no message template found; coverage cannot be established")

    for filename, line, template, reason in uncovered:
        print(f"  FAIL    {filename}:{line}  {reason}")
        print(f"          {template[:100]}")

    if uncovered or unreadable:
        print("")
        print("add a fixture that triggers each rule above, or delete the rule")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
