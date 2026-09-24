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
K8S_DIR     := controls/kubernetes
GATE        := $(POLICY_DIR)/gate.sh

PLAN_EKS     := $(TF_EKS)/plan.json
PLAN_BEDROCK := $(TF_BEDROCK)/plan.json
PLAN_FIXTURE := $(FIXTURE_DIR)/plan.json

# Rendering a plan is the slowest step in the chain. The plans are declared as
# real file targets so a target that needs one does not re-render a plan that
# is already newer than the Terraform that produced it. `make demo` used to
# plan twice and print the same four lines twice on screen.
MODULE_SRC := $(wildcard controls/terraform/modules/*/*.tf)

# Strip any real AWS credentials from the environment so the offline claim is
# enforced rather than assumed.
NO_AWS := env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE

.PHONY: help init fmt validate plan plan-insecure policy policy-plan policy-negative \
        policy-k8s policy-k8s-negative policy-coverage \
        ci demo clean

help:
	@echo "make demo            full walkthrough for the presentation"
	@echo "make ci              the gate chain the pipeline enforces"
	@echo "make plan            render the AI layer offline"
	@echo "make policy          prove the AI layer passes every rule"
	@echo "make policy-plan     run the rules against a plan.json (PLAN=...)"
	@echo "make policy-negative prove the gate rejects insecure config"
	@echo "make policy-k8s      prove the workload manifests pass every rule"
	@echo "make policy-coverage prove every rule fires against a fixture"
	@echo "make clean           remove generated plan artefacts"
	@echo ""
	@echo "A real cluster runs in the pipeline, not here: security.yml starts a"
	@echo "kind cluster, has admission refuse a privileged pod, and runs"
	@echo "controls/kubernetes/prove-networkpolicy.sh against it."

init:
	@$(TF) -chdir=$(TF_EKS) init -input=false -no-color >/dev/null
	@$(TF) -chdir=$(TF_BEDROCK) init -input=false -no-color >/dev/null
	@$(TF) -chdir=$(FIXTURE_DIR) init -input=false -no-color >/dev/null
	@echo "providers installed"

fmt:
	@$(TF) -chdir=controls/terraform fmt -check -recursive

# `validate` needs the modules on disk. A clean checkout has no .terraform/,
# so CI failed here with "Module not installed" until init became a prerequisite.
validate: init
	@$(TF) -chdir=$(TF_EKS) validate -no-color
	@$(TF) -chdir=$(TF_BEDROCK) validate -no-color

$(PLAN_BEDROCK): $(wildcard $(TF_BEDROCK)/*.tf) $(MODULE_SRC)
	@$(TF) -chdir=$(TF_BEDROCK) init -input=false -no-color >/dev/null
	@$(NO_AWS) $(TF) -chdir=$(TF_BEDROCK) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(TF_BEDROCK) show -json tf.plan > $@

$(PLAN_FIXTURE): $(wildcard $(FIXTURE_DIR)/*.tf)
	@$(TF) -chdir=$(FIXTURE_DIR) init -input=false -no-color >/dev/null
	@$(NO_AWS) $(TF) -chdir=$(FIXTURE_DIR) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(FIXTURE_DIR) show -json tf.plan > $@

# The AI layer renders offline. The platform layer does not, since it was moved
# onto terraform-aws-modules/eks, which reads aws_caller_identity and two other
# data sources during plan. That layer is gated against its real plan in the
# deploy pipeline instead -- stronger evidence, on later evidence: the bytes
# checked are the bytes applied, not an offline approximation of them.
plan: $(PLAN_BEDROCK)
	@echo "bedrock-ai layer:   $$(jq '[.resource_changes[] | select(.mode == "managed")] | length' $(PLAN_BEDROCK)) resources planned offline"
	@echo "no AWS account contacted"

plan-insecure: $(PLAN_FIXTURE)

# The layer that can be rendered without an account.
policy: $(PLAN_BEDROCK)
	@$(GATE) pass $(PLAN_BEDROCK) "bedrock-ai layer    (guardrail, corpus, vectors, identity)"

# The platform layer, against a real plan. Needs AWS credentials, which is why
# it is not part of `make ci`; the deploy pipeline runs this on the saved plan
# it is about to apply.
policy-plan:
	@test -n "$(PLAN)" || { echo "usage: make policy-plan PLAN=path/to/plan.json"; exit 2; }
	@$(GATE) pass $(PLAN) "planned infrastructure"

# The insecure fixture must FAIL. A policy that has only ever passed has not
# been tested, so a clean run here is itself a failure.
policy-negative: $(PLAN_FIXTURE)
	@$(GATE) fail $(PLAN_FIXTURE) "insecure Terraform fixture"

# The workload manifests must satisfy every rule. conftest reads Kubernetes
# YAML directly, so one gate covers infrastructure and workloads alike.
policy-k8s:
	@$(GATE) pass $(K8S_DIR)/base/ "workload manifests"

# The bad manifests must FAIL, for the same reason the insecure Terraform
# fixture must fail.
policy-k8s-negative:
	@$(GATE) fail $(K8S_DIR)/bad/ "insecure workload manifests"

# A rule that has never fired is not a control, it is a comment. This proves
# every rule in the policy directory rejects something in a fixture.
policy-coverage: $(PLAN_FIXTURE)
	@$(POLICY_DIR)/coverage.py

# Live cluster proof runs in the pipeline, not here. `security.yml` starts a
# kind cluster, applies the namespace, sends the privileged pod at admission and
# requires it to be refused, then runs prove-networkpolicy.sh against the same
# cluster. Static policy proves the manifests are correct; that job proves a
# real cluster enforces them, which is a different claim and needs no podman on
# a workstation.

ci: fmt validate policy policy-negative policy-k8s policy-k8s-negative policy-coverage
	@echo ""
	@echo "all security gates passed"

# The presentation walkthrough. Kept under a minute and under forty lines on
# screen: the negative steps print five examples and a count rather than every
# violation, because nobody reads fifty red lines. `make policy-negative` on its
# own prints the full list.
demo: export SHOW = 5
demo:
	@echo "=================================================================="
	@echo " 1. Render the infrastructure offline. No AWS account, no cost."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory plan
	@echo ""
	@echo "=================================================================="
	@echo " 2. The AI layer must satisfy every security rule."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy
	@echo ""
	@echo "=================================================================="
	@echo " 3. Now try to deploy something insecure. The gate must refuse."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy-negative
	@echo ""
	@echo "=================================================================="
	@echo " 4. The same gate reads the workload manifests."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy-k8s
	@echo ""
	@$(MAKE) --no-print-directory policy-k8s-negative
	@echo ""
	@echo "=================================================================="
	@echo " 5. And every rule is proven to reject something."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy-coverage

clean:
	@rm -f $(TF_BEDROCK)/tf.plan $(TF_BEDROCK)/plan.json
	@rm -f $(TF_EKS)/tf.plan $(TF_EKS)/plan.json
	@rm -f $(FIXTURE_DIR)/tf.plan $(FIXTURE_DIR)/plan.json
	@echo "generated artefacts removed"
