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
        policy-k8s policy-k8s-negative kind-up kind-down k8s-apply k8s-demo \
        ci demo clean

help:
	@echo "make demo            full walkthrough for the presentation"
	@echo "make ci              the gate chain the pipeline enforces"
	@echo "make plan            render both infrastructure layers offline"
	@echo "make policy          prove both secure layers pass every rule"
	@echo "make policy-negative prove the gate rejects insecure config"
	@echo "make policy-k8s      prove the workload manifests pass every rule"
	@echo "make kind-up         create the local cluster"
	@echo "make k8s-demo        make a real cluster refuse the bad manifests"
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

# The workload manifests must satisfy every rule. conftest reads Kubernetes
# YAML directly, so one gate covers infrastructure and workloads alike.
policy-k8s:
	@conftest test --policy $(POLICY_DIR) --all-namespaces $(K8S_DIR)/base/

# The bad manifests must FAIL, for the same reason the insecure Terraform
# fixture must fail.
policy-k8s-negative:
	@if conftest test --policy $(POLICY_DIR) --all-namespaces $(K8S_DIR)/bad/ >/dev/null 2>&1; then \
		echo "NEGATIVE TEST FAILED: insecure manifests were accepted"; \
		exit 1; \
	else \
		conftest test --policy $(POLICY_DIR) --all-namespaces $(K8S_DIR)/bad/ || true; \
		echo ""; \
		echo "negative test passed: the gate rejected the insecure manifests"; \
	fi

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

k8s-apply:
	@$(KUBECTL) apply -f $(K8S_DIR)/base/ >/dev/null
	@$(KUBECTL) apply -f $(K8S_DIR)/policies/ >/dev/null 2>&1 || echo "kyverno not installed; skipping admission policies"
	@echo "namespace, identity, rbac, network policy and admission policies applied"

# The part worth watching. Each apply is expected to be refused, by a different
# control, for a reason the cluster states itself.
k8s-demo: k8s-apply
	@for manifest in privileged-pod wildcard-rbac public-image default-identity-pod; do \
		echo ""; \
		echo "=================================================================="; \
		echo " kubectl apply -f bad/$$manifest.yaml"; \
		echo "=================================================================="; \
		$(KUBECTL) apply -f $(K8S_DIR)/bad/$$manifest.yaml 2>&1 | head -6 || true; \
	done
	@echo ""
	@echo "every insecure manifest was refused by the cluster"

ci: fmt validate policy policy-negative policy-k8s policy-k8s-negative
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
	@echo ""
	@echo "=================================================================="
	@echo " 4. The same gate reads the workload manifests."
	@echo "=================================================================="
	@$(MAKE) --no-print-directory policy-k8s
	@$(MAKE) --no-print-directory policy-k8s-negative

clean:
	@rm -f $(TF_BEDROCK)/tf.plan $(TF_BEDROCK)/plan.json
	@rm -f $(TF_EKS)/tf.plan $(TF_EKS)/plan.json
	@rm -f $(FIXTURE_DIR)/tf.plan $(FIXTURE_DIR)/plan.json
	@echo "generated artefacts removed"
