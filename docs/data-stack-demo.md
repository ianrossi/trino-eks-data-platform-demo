# Data Stack Demo

This demo runs open source data infrastructure on EKS without managed data
services. Terraform creates the AWS and EKS foundation, ArgoCD reconciles the
Kubernetes services, Karpenter supplies data workload capacity, and the data
systems run as Kubernetes workloads.

## Components

- ArgoCD is the GitOps control plane for long-running services.
- Karpenter launches EC2 capacity when data pods cannot fit on existing nodes.
- Trino is the SQL federation layer.
- Spark Operator runs Spark applications as Kubernetes custom resources.
- Pinot is the low-latency OLAP serving layer.

## Deploy The Services

The ArgoCD Application examples live in `gitops/applications/`.

```bash
kubectl apply -f gitops/applications/trino.yaml.example
kubectl apply -f gitops/applications/spark-operator.yaml.example
kubectl apply -f gitops/applications/pinot.yaml.example
```

If the Spark Operator CRDs are too large for client-side apply, apply the chart
CRDs with server-side apply before syncing the ArgoCD app:

```bash
helm show crds spark-operator \
  --repo https://kubeflow.github.io/spark-operator \
  --version 2.1.1 |
kubectl apply --server-side -f -
```

Check the GitOps state:

```bash
kubectl get applications -n argocd -o wide
```

Expected result:

```text
NAME             SYNC STATUS   HEALTH STATUS
pinot            Synced        Healthy
spark-operator   Synced        Healthy
trino            Synced        Healthy
```

## Run The Pipelines

Create the Spark namespace and run Spark Pi:

```bash
kubectl apply -f kubernetes/pipelines/spark-namespace.yaml
kubectl apply -f kubernetes/pipelines/spark-pi.yaml
kubectl get sparkapplication -n spark spark-pi -o wide
kubectl logs -n spark spark-pi-driver | grep "Pi is"
```

Run a Trino memory-catalog smoke test:

```bash
kubectl apply -f kubernetes/pipelines/trino-memory-smoke-job.yaml
kubectl wait --for=condition=complete job/trino-memory-smoke -n trino --timeout=5m
kubectl logs -n trino job/trino-memory-smoke
```

Bootstrap and ingest Pinot's bundled airline sample:

```bash
kubectl delete job -n pinot pinot-airline-bootstrap --ignore-not-found
kubectl apply -f kubernetes/pipelines/pinot-airline-bootstrap-job.yaml
kubectl wait --for=condition=complete job/pinot-airline-bootstrap -n pinot --timeout=10m
```

Verify Pinot directly:

```bash
kubectl exec -n pinot pinot-broker-0 -- \
  curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"sql":"select count(*) from airlineStats"}' \
  http://localhost:8099/query/sql
```

Verify the same Pinot table through Trino:

```bash
kubectl exec -n trino deploy/trino-coordinator -- \
  /usr/bin/trino --server http://localhost:8080 \
  --execute 'SHOW TABLES FROM pinot.default; SELECT count(*) FROM pinot.default.airlinestats'
```

## Proven Result

On the demo cluster, the stack produced:

- Spark completed `spark-pi` and logged `Pi is roughly 3.1406957034785172`.
- Trino created a memory table and grouped four sample orders by region.
- Pinot ingested 31 offline airline segments.
- Pinot returned `9746` rows for `select count(*) from airlineStats`.
- Trino returned `9746` rows from `pinot.default.airlinestats`.
- Karpenter launched Spot data nodes for the service pods and the Pinot ingestion job.

## Realtime Extension

The realtime demo adds a Kafka-compatible stream and a relational dimension
store:

```text
Redpanda
  Kafka-compatible topic: realtime-orders

Synthetic producer
  Writes one JSON order event per second

Pinot realtime table
  Consumes realtime-orders from Redpanda

Postgres
  Stores carrier_dim reference data

Trino
  Joins Pinot realtime facts to Postgres dimensions
```

Deploy the supporting services:

```bash
kubectl apply -f gitops/applications/postgresql.yaml.example
kubectl apply -f gitops/applications/trino.yaml.example
kubectl apply -k kubernetes/streaming
```

Verify Redpanda and the producer:

```bash
kubectl get pods -n streaming
kubectl logs -n streaming deploy/realtime-orders-producer --tail=20
```

Verify Pinot is consuming realtime rows:

```bash
kubectl exec -n pinot pinot-broker-0 -- \
  curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"sql":"select count(*) from realtimeOrders"}' \
  http://localhost:8099/query/sql
```

Verify Trino can see both catalogs:

```bash
kubectl exec -n trino deploy/trino-coordinator -- \
  /usr/bin/trino --server http://localhost:8080 \
  --execute 'SHOW TABLES FROM pinot.default; SHOW TABLES FROM postgresql.public'
```

Run the federated realtime join:

```bash
kubectl exec -n trino deploy/trino-coordinator -- \
  /usr/bin/trino --server http://localhost:8080 \
  --execute "SELECT d.carrier_name, d.alliance, count(*) AS realtime_orders, round(sum(o.amount), 2) AS revenue FROM pinot.default.realtimeorders o JOIN postgresql.public.carrier_dim d ON o.carrier_code = d.carrier_code GROUP BY d.carrier_name, d.alliance ORDER BY realtime_orders DESC"
```

This demonstrates the interview-relevant pattern: Pinot serves fresh events from
a Kafka-compatible stream, Postgres holds dimensions, and Trino federates across
both without moving the data into one database first.

## Access UIs

For interview/demo use, prefer the supervised local port-forward script:

```bash
cd /path/to/trino-eks-project
tmux new-session -d -s trino-demo-pf -n forwards \
  "cd \"$PWD\" && scripts/demo_port_forwards.sh"
```

It keeps these local URLs available and reconnects if a port-forward drops:

- ArgoCD: `https://localhost:8080`
- Trino: `http://localhost:8081/ui/`
- Pinot Controller: `http://localhost:9000`

Check or stop it with:

```bash
tmux ls
tmux attach -t trino-demo-pf
tmux kill-session -t trino-demo-pf
```

Manual one-off commands are still useful for troubleshooting:

ArgoCD:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080`.

Trino:

```bash
kubectl -n trino port-forward svc/trino 8081:8080
```

Open `http://localhost:8081`.

Pinot Controller:

```bash
kubectl -n pinot port-forward svc/pinot-controller 9000:9000
```

Open `http://localhost:9000`.

## Interview Narrative

The platform separates responsibilities cleanly. Terraform builds the cloud
foundation. ArgoCD owns Kubernetes application reconciliation. Karpenter turns
pending data pods into right-sized EC2 capacity. Spark is the batch compute
path. Pinot is the serving path for low-latency analytical queries. Trino sits
above those systems and gives users one SQL entrypoint.

For production, Pinot should not use ephemeral storage. This demo disables
Pinot persistence because the current cluster has EFS CSI but not EBS CSI.
Production Pinot should use persistent volumes, deep storage, backups, pod
disruption budgets, and clearer workload separation between ingestion and
serving nodes. The realtime extension also uses ephemeral Redpanda and Postgres
storage; production should use durable volumes, topic retention policy,
replication, secrets management, and proper authentication/TLS.
