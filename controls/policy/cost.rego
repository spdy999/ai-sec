# Control: cost as a security property.
#
# Two of the ways a GenAI platform fails are financial before they are anything
# else. A stolen workload identity spending on model tokens shows up as a cost
# curve; so does an infrastructure change that quietly provisions capacity
# nobody reviewed. A platform with no cost ceiling has no early warning for
# either, and no upper bound on the damage.
package main

import rego.v1

import data.lib

# OpenSearch Serverless bills per OCU-hour whether the collection is queried
# once or never. Redundancy defaults to enabled, which provisions four OCUs and
# makes the vector store the largest line on the bill by a wide margin.
deny contains msg if {
	some resource in lib.typed("aws_opensearchserverless_collection")

	object.get(resource, ["values", "standby_replicas"], "ENABLED") == "ENABLED"

	msg := sprintf(
		"cost: %s runs with standby replicas enabled, which doubles it to 4 OCUs; non-production collections must set standby_replicas = \"DISABLED\"",
		[resource.address],
	)
}

# Any stack that stands up a cluster must also declare what it is allowed to
# cost. The budget is free; its absence is the difference between noticing an
# incident on day one and noticing it on the invoice.
deny contains msg if {
	count(lib.typed("aws_eks_cluster")) > 0
	count(lib.typed("aws_budgets_budget")) == 0

	msg := "cost: the platform declares a cluster but no aws_budgets_budget; there is no ceiling and no forecast alert"
}

deny contains msg if {
	some resource in lib.typed("aws_budgets_budget")

	count(object.get(resource, ["values", "notification"], [])) == 0

	msg := sprintf(
		"cost: %s has no notification block, so breaching the ceiling alerts nobody",
		[resource.address],
	)
}

# Retention is where data minimisation and log spend point the same way.
# Prompt and response text is confidential; keeping it for a decade multiplies
# both the bill and the blast radius of a log-store compromise.
max_log_retention_days := 400

deny contains msg if {
	some resource in lib.typed("aws_cloudwatch_log_group")

	retention := object.get(resource, ["values", "retention_in_days"], 0)
	retention > max_log_retention_days

	msg := sprintf(
		"cost: %s retains logs for %d days; confidential prompt text must not be kept beyond %d",
		[resource.address, retention, max_log_retention_days],
	)
}
