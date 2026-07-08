# Open Source Data Infrastructure on Amazon EKS

This project is a hands-on interview-prep demo for building open source data
infrastructure on Amazon EKS. It provisions an EKS cluster with Terraform,
installs Karpenter for workload-aware node provisioning, bootstraps ArgoCD, and
deploys Trino, Spark Operator, and Apache Pinot with runnable sample pipelines.

The point of the project is not to use managed data services. The point is to
show how open source data systems can be run on Kubernetes in a repeatable,
well-architected way.

## What Is Built

- VPC with public and private subnets across EKS-supported `us-east-1` AZs.
- EKS 1.30 cluster with a small managed node group for system pods.
- Core EKS addons: VPC CNI, CoreDNS, kube-proxy, and EKS Pod Identity Agent.
- Karpenter v1 installed by Helm in `kube-system`, with IAM, interruption
  queue, and node role.
- Karpenter `EC2NodeClass` and `NodePool` for elastic data workloads.
- ArgoCD installed in-cluster as the GitOps control plane.
- ArgoCD Application manifests for Karpenter NodePool, Trino, Spark Operator,
  and Pinot.
- Demo pipelines for Spark, Trino, and Pinot.

## Architecture

```text
Terraform
  VPC, subnets, EKS, IAM, managed node group, Karpenter install

Karpenter
  Watches pending pods and launches right-sized EC2 nodes

ArgoCD
  Reconciles Kubernetes workloads from Git

Data workloads
  Trino: SQL query engine
  Spark Operator: declarative Spark jobs
  Pinot: real-time OLAP serving layer
```

Terraform owns AWS infrastructure. ArgoCD owns Kubernetes application delivery.
That split is intentional: infrastructure changes and application lifecycle
changes move at different speeds.

## Why Karpenter Instead Of Only Node Group Autoscaling?

EKS node autoscaling exists. The common traditional setup is managed node groups
plus Cluster Autoscaler. That works well when you have a small number of stable,
predefined node pools.

Karpenter is a better fit for mixed data workloads because it can choose
instance types dynamically based on pending pod requirements. Spark executors,
Trino workers, and Pinot servers do not all want the same compute profile.
Karpenter can launch a compute-optimized, memory-optimized, Spot, or On-Demand
node without predefining every possible node group.

Interview framing:

> Managed node group autoscaling scales groups I already defined. Karpenter
> provisions capacity based on the workload that is pending now.

## Repository Layout

```text
terraform/
  main.tf                  # AWS, EKS, Karpenter, and Spot prerequisite
  karpenter-values.yaml    # Helm values for the Karpenter controller

kubernetes/karpenter/
  nodepool.yaml            # Live Karpenter NodePool/EC2NodeClass manifest
  smoke-workload.yaml      # Temporary workload to prove Karpenter launches nodes

kubernetes/pipelines/
  spark-pi.yaml                    # SparkApplication smoke test
  trino-memory-smoke-job.yaml      # Trino SQL smoke test
  pinot-airline-bootstrap-job.yaml # Pinot table bootstrap and ingestion

gitops/
  apps/karpenter-nodepool/ # Kustomize app for ArgoCD once pushed to Git
  applications/            # ArgoCD Application examples

scripts/
  eks_kubeconfig.py        # Temporary kubeconfig helper when aws CLI is unavailable
```

## Prerequisites

- AWS credentials with permissions for VPC, EKS, IAM, EC2, SQS, EventBridge, and
  Helm/Kubernetes access to the created cluster.
- Terraform 1.5+.
- Helm 3.
- kubectl.
- Python with `boto3` and `botocore` for the helper script.

This repo intentionally ignores Terraform state and local binaries.

## Build The Platform

```bash
cd terraform
terraform init
terraform validate
terraform apply
```

If the local `terraform` binary is not installed globally, use the binary you
downloaded separately. Do not commit it.

## Access The EKS Cluster

The normal path is:

```bash
aws eks update-kubeconfig --region us-east-1 --name trino-eks-karpenter
```

If your local AWS CLI is broken, use the included helper:

```bash
scripts/eks_kubeconfig.py --output /tmp/trino-eks-kubeconfig
export KUBECONFIG=/tmp/trino-eks-kubeconfig
kubectl get nodes
```

The helper writes a short-lived token-based kubeconfig.

## Prove Karpenter Works

Apply the durable Karpenter capacity policy:

```bash
kubectl apply -f kubernetes/karpenter/nodepool.yaml
kubectl get ec2nodeclass,nodepool
```

Run a temporary workload that exceeds the system node group capacity:

```bash
kubectl apply -f kubernetes/karpenter/smoke-workload.yaml
kubectl rollout status deployment/karpenter-smoke --timeout=8m
kubectl get pods -l app=karpenter-smoke -o wide
kubectl get nodeclaim,nodepool -o wide
kubectl get nodes -L workload-class,karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

Expected result:

- Pods start as Pending due to insufficient CPU.
- Karpenter creates a NodeClaim.
- An EC2 node joins the cluster with `workload-class=data` and
  `karpenter.sh/nodepool=data-general`.
- Pending pods schedule onto that node.

Clean up the test workload:

```bash
kubectl delete -f kubernetes/karpenter/smoke-workload.yaml
```

Karpenter should consolidate the empty node after the configured delay.

## ArgoCD

ArgoCD is installed with Helm:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --wait
```

Access the UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Then open `https://localhost:8080`.

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

The `gitops/applications/*.yaml.example` files are ready to use from the public
repo URL. Remove the `.example` suffixes as desired, review the Helm values, and
apply them to the `argocd` namespace.

## Data Stack Demo

Use ArgoCD to deploy the data layer:

- Trino through the Trino Helm chart.
- Spark through the Kubeflow Spark Operator Helm chart.
- Pinot through the Apache Pinot Helm chart.

Then run the pipeline examples:

```bash
kubectl apply -f kubernetes/pipelines/spark-namespace.yaml
kubectl apply -f kubernetes/pipelines/spark-pi.yaml
kubectl apply -f kubernetes/pipelines/trino-memory-smoke-job.yaml
kubectl delete job -n pinot pinot-airline-bootstrap --ignore-not-found
kubectl apply -f kubernetes/pipelines/pinot-airline-bootstrap-job.yaml
```

See [docs/data-stack-demo.md](docs/data-stack-demo.md) for the full runbook,
verification commands, and interview narrative.

## Interview Talking Points

- Separate system capacity from elastic data workload capacity.
- Use private subnets for worker nodes.
- Tag subnets and security groups for Karpenter discovery.
- Keep Terraform focused on cloud infrastructure.
- Use ArgoCD for Kubernetes application reconciliation.
- Explain how Karpenter reacts to unschedulable pods and picks instance types.
- Discuss Spot service-linked role prerequisites and interruption handling.
- For production, add remote Terraform state, restricted API endpoint access,
  secrets management, observability, backup/deep storage, and GitHub Actions.

## References

- Trino Helm chart docs: https://trino.io/docs/current/installation/kubernetes.html
- Trino chart repository: https://github.com/trinodb/charts
- Apache Spark Kubernetes Operator: https://github.com/apache/spark-kubernetes-operator
- Spark Operator Helm docs: https://www.kubeflow.org/docs/components/spark-operator/getting-started/
- Apache Pinot Kubernetes deployment: https://docs.pinot.apache.org/operate-pinot/kubernetes-production/deployment-pinot-on-kubernetes
