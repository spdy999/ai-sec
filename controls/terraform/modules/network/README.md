# network

The VPC that hosts the mediation layer, and the evidence trail for traffic
inside it.

The defining property is what this module does **not** create: there is no
internet gateway, no NAT gateway, and no default route. Nothing in the VPC can
reach the internet. Every AWS API the workload needs arrives through a VPC
endpoint instead.

That single decision removes the exfiltration path. A prompt injection that
convinces the assistant to POST the HR corpus to an attacker's server produces a
connection timeout, and a flow log record showing the attempt.
