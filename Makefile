KUBECONFIG_PATH ?= /tmp/trino-eks-kubeconfig
CLUSTER_NAME ?= trino-eks-karpenter
AWS_REGION ?= us-east-1
TERRAFORM ?= terraform

.PHONY: kubeconfig tf-validate tf-plan tf-apply argocd-status karpenter-apply karpenter-test karpenter-clean gitops-dry-run

kubeconfig:
	scripts/eks_kubeconfig.py --cluster $(CLUSTER_NAME) --region $(AWS_REGION) --output $(KUBECONFIG_PATH)

tf-validate:
	cd terraform && $(TERRAFORM) validate

tf-plan:
	cd terraform && $(TERRAFORM) plan

tf-apply:
	cd terraform && $(TERRAFORM) apply

argocd-status: kubeconfig
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl -n argocd get pods

gitops-dry-run: kubeconfig
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl apply --dry-run=server -k gitops/apps/karpenter-nodepool

karpenter-apply: kubeconfig
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl apply -f kubernetes/karpenter/nodepool.yaml
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl get ec2nodeclass,nodepool

karpenter-test: kubeconfig
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl apply -f kubernetes/karpenter/smoke-workload.yaml
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl rollout status deployment/karpenter-smoke --timeout=8m
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl get pods -l app=karpenter-smoke -o wide
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl get nodeclaim,nodepool -o wide
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl get nodes -L workload-class,karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

karpenter-clean: kubeconfig
	KUBECONFIG=$(KUBECONFIG_PATH) kubectl delete -f kubernetes/karpenter/smoke-workload.yaml --ignore-not-found
