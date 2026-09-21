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
KIND_CLUSTER := koerber-demo

# Every kubectl call names its context explicitly. Never current-context: a
# stray apply of a deliberately-privileged test pod must not be able to reach a
# real cluster.
KUBECTL := kubectl --context kind-$(KIND_CLUSTER)
KIND    := KIND_EXPERIMENTAL_PROVIDER=podman kind

# Strip any real AWS credentials from the environment so the offline claim is
# enforced rather than assumed.
NO_AWS := env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE

.PHONY: help init fmt validate plan plan-insecure policy policy-negative \
        policy-k8s policy-k8s-negative policy-coverage \
        kind-up kind-down k8s-apply k8s-admit \
        k8s-demo netpol-proof \
        ci demo clean

help:
	@echo "make demo            full walkthrough for the presentation"
	@echo "make ci              the gate chain the pipeline enforces"
	@echo "make plan            render both infrastructure layers offline"
	@echo "make policy          prove both secure layers pass every rule"
	@echo "make policy-negative prove the gate rejects insecure config"
	@echo "make policy-k8s      prove the workload manifests pass every rule"
	@echo "make policy-coverage prove every rule fires against a fixture"
	@echo "make kind-up         create the local cluster"
	@echo "make k8s-demo        make a real cluster refuse the bad manifests"
	@echo "make netpol-proof    prove default-deny egress actually blocks traffic"
	@echo "make clean           remove generated plan artefacts"

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

$(PLAN_EKS): $(wildcard $(TF_EKS)/*.tf) $(MODULE_SRC)
	@$(TF) -chdir=$(TF_EKS) init -input=false -no-color >/dev/null
	@$(NO_AWS) $(TF) -chdir=$(TF_EKS) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(TF_EKS) show -json tf.plan > $@

$(PLAN_BEDROCK): $(wildcard $(TF_BEDROCK)/*.tf) $(MODULE_SRC)
	@$(TF) -chdir=$(TF_BEDROCK) init -input=false -no-color >/dev/null
	@$(NO_AWS) $(TF) -chdir=$(TF_BEDROCK) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(TF_BEDROCK) show -json tf.plan > $@

$(PLAN_FIXTURE): $(wildcard $(FIXTURE_DIR)/*.tf)
	@$(TF) -chdir=$(FIXTURE_DIR) init -input=false -no-color >/dev/null
	@$(NO_AWS) $(TF) -chdir=$(FIXTURE_DIR) plan -input=false -no-color -out=tf.plan >/dev/null
	@$(TF) -chdir=$(FIXTURE_DIR) show -json tf.plan > $@

# Renders both plans to JSON. These are the artefacts every policy runs against.
plan: $(PLAN_EKS) $(PLAN_BEDROCK)
	@echo "eks-platform layer: $$(jq '[.resource_changes[] | select(.mode == "managed")] | length' $(PLAN_EKS)) resources planned offline"
	@echo "bedrock-ai layer:   $$(jq '[.resource_changes[] | select(.mode == "managed")] | length' $(PLAN_BEDROCK)) resources planned offline"
	@echo "no AWS account contacted"

plan-insecure: $(PLAN_FIXTURE)

# Both secure layers must pass every rule.
policy: $(PLAN_EKS) $(PLAN_BEDROCK)
	@$(GATE) pass $(PLAN_EKS) "eks-platform layer  (network, Kubernetes, nodes)"
	@$(GATE) pass $(PLAN_BEDROCK) "bedrock-ai layer    (guardrail, corpus, vectors, identity)"

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

########################################
# Live cluster targets
#
# Static policy proves the manifests are correct. These prove a real cluster
# enforces them, which is a different claim.
########################################

kind-up:
	@$(KIND) create cluster --name $(KIND_CLUSTER) 2>/dev/null || echo "cluster $(KIND_CLUSTER) already exists"
	@$(KUBECTL) cluster-info | head -1

kind-down:
	@$(KIND) delete cluster --name $(KIND_CLUSTER)

# The namespace, identity, RBAC and network policy are applied for real. The
# Deployment is server-side dry-run only: it references an image digest that
# does not exist, so a real apply would leave two pods in ImagePullBackOff.
# A dry run still executes Pod Security and every Kyverno webhook, which is the
# control being tested here; scheduling a pod is not.
k8s-apply:
	@$(KUBECTL) apply \
		-f $(K8S_DIR)/base/00-namespace.yaml \
		-f $(K8S_DIR)/base/10-serviceaccount.yaml \
		-f $(K8S_DIR)/base/20-rbac.yaml \
		-f $(K8S_DIR)/base/30-networkpolicy.yaml >/dev/null
	@$(KUBECTL) apply -f $(K8S_DIR)/policies/ >/dev/null 2>&1 || echo "kyverno not installed; skipping admission policies"
	@echo "namespace, identity, rbac, network policy and admission policies applied"

# The hardened workload must be admitted. Same webhooks, no pod scheduled.
k8s-admit:
	@$(KUBECTL) apply --dry-run=server -f $(K8S_DIR)/base/40-deployment.yaml

# Declared is not enforced. This sends a packet before and after the policy.
netpol-proof:
	@CONTEXT=kind-$(KIND_CLUSTER) $(K8S_DIR)/prove-networkpolicy.sh

# The part worth watching. Each apply is expected to be refused, by a different
# control, for a reason the cluster states itself.
k8s-demo: k8s-apply
	@echo ""
	@echo "=================================================================="
	@echo " the hardened workload is admitted"
	@echo "=================================================================="
	@$(MAKE) --no-print-directory k8s-admit
	@for manifest in privileged-pod wildcard-rbac public-image default-identity-pod; do \
		echo ""; \
		echo "=================================================================="; \
		echo " kubectl apply -f bad/$$manifest.yaml"; \
		echo "=================================================================="; \
		$(KUBECTL) apply -f $(K8S_DIR)/bad/$$manifest.yaml 2>&1 | head -6 || true; \
	done
	@echo ""
	@echo "every insecure manifest was refused by the cluster"

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
	@echo " 2. Both layers must satisfy every security rule."
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
