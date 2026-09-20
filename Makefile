# Security gate chain for the Korber GenAI platform assignment.
#
# Every target runs locally at zero cost. Nothing is deployed and no AWS
# credentials are required: `terraform plan` renders the infrastructure graph
# offline with mock credentials, and the policy engine reads that graph as a
# file.
#
#   make demo   <- run this in the presentation
#   make ci     <- the exact gate chain the pipeline runs

TF          := terraform
TF_BEDROCK   := controls/terraform/bedrock-ai
TF_EKS       := controls/terraform/eks-platform
FIXTURE_DIR := controls/terraform/fixtures/insecure
POLICY_DIR  := controls/policy

# Strip any real AWS credentials from the environment so the offline claim is
# enforced rather than assumed.
NO_AWS := env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE

.PHONY: help init fmt validate plan plan-insecure policy policy-negative ci demo clean

help:
	@echo "make demo            full walkthrough for the presentation"
	@echo "make ci              the gate chain the pipeline enforces"
	@echo "make plan            render both infrastructure layers offline"
	@echo "make policy          prove both secure layers pass every rule"
	@echo "make policy-negative prove the gate rejects insecure config"
	@echo "make clean           remove generated plan artefacts"

init:
	@$(TF) -chdir=$(TF_EKS) init -input=false -no-color >/dev/null
	@$(TF) -chdir=$(TF_BEDROCK) init -input=false -no-color >/dev/null
	@$(TF) -chdir=$(FIXTURE_DIR) init -input=false -no-color >/dev/null
	@echo "providers installed"

fmt:
	@$(TF) -chdir=controls/terraform fmt -check -recursive

validate:
	@$(TF) -chdir=$(TF_EKS) validate -no-color
	@$(TF) -chdir=$(TF_BEDROCK) validate -no-color

# Renders both plans to JSON. These are the artefacts every policy runs against.
plan: init
	@$(NO_AWS) $(TF) -chdir=$(TF_EKS) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(TF_EKS) show -json tf.plan > $(TF_EKS)/plan.json
	@$(NO_AWS) $(TF) -chdir=$(TF_BEDROCK) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(TF_BEDROCK) show -json tf.plan > $(TF_BEDROCK)/plan.json
	@echo "eks-platform layer: $$($(TF) -chdir=$(TF_EKS) show -json tf.plan | jq '[.resource_changes[] | select(.mode == "managed")] | length') resources planned offline"
	@echo "bedrock-ai layer:   $$($(TF) -chdir=$(TF_BEDROCK) show -json tf.plan | jq '[.resource_changes[] | select(.mode == "managed")] | length') resources planned offline"
	@echo "no AWS account contacted"

plan-insecure: init
	@$(NO_AWS) $(TF) -chdir=$(FIXTURE_DIR) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(FIXTURE_DIR) show -json tf.plan > $(FIXTURE_DIR)/plan.json

# Both secure layers must pass every rule.
policy: plan
	@echo "-- eks-platform layer: network, Kubernetes, nodes --"
	@conftest test --policy $(POLICY_DIR) --all-namespaces $(TF_EKS)/plan.json
	@echo "-- bedrock-ai layer: guardrail, corpus, vectors, workload identity --"
	@conftest test --policy $(POLICY_DIR) --all-namespaces $(TF_BEDROCK)/plan.json

# The insecure fixture must FAIL. A policy that has only ever passed has not
# been tested, so a clean run here is itself a failure.
policy-negative: plan-insecure
	@if conftest test --policy $(POLICY_DIR) --all-namespaces $(FIXTURE_DIR)/plan.json >/dev/null 2>&1; then \
		echo "NEGATIVE TEST FAILED: insecure fixture was accepted by the policy gate"; \
		exit 1; \
	else \
		conftest test --policy $(POLICY_DIR) --all-namespaces $(FIXTURE_DIR)/plan.json || true; \
		echo ""; \
		echo "negative test passed: the gate rejected the insecure configuration"; \
	fi

ci: fmt validate policy policy-negative
	@echo ""
	@echo "all security gates passed"

demo:
	@echo "=================================================================="
	@echo " 1. Render the infrastructure offline. No AWS account, no cost."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory plan
	@echo ""
	@echo "=================================================================="
	@echo " 2. Both layers must satisfy every security rule."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy
	@echo ""
	@echo "=================================================================="
	@echo " 3. Now try to deploy something insecure. The gate must refuse."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy-negative

clean:
	@rm -f $(TF_BEDROCK)/tf.plan $(TF_BEDROCK)/plan.json
	@rm -f $(TF_EKS)/tf.plan $(TF_EKS)/plan.json
	@rm -f $(FIXTURE_DIR)/tf.plan $(FIXTURE_DIR)/plan.json
	@echo "generated artefacts removed"
