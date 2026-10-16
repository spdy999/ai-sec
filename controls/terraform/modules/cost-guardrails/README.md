# cost-guardrails

A monthly budget with forecast alerts, and an anomaly monitor on the services
this platform uses.

This is a security control, not an accounting one. Two of the ways a GenAI
platform fails are financial: a stolen workload identity used to mine tokens
against an expensive model, and an infrastructure change that quietly
provisions capacity nobody asked for. Both look like a cost curve before they
look like anything else.

The budget is also the only thing standing between a forgotten `terraform
apply` and a four-figure invoice. It costs nothing to create.

Alerts fire on **forecast**, not only on actual spend, so the warning arrives
while there is still time to act.
