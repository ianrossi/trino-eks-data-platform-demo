#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/trino-eks-kubeconfig}"
LOG_DIR="${LOG_DIR:-/tmp/trino-eks-demo-port-forwards}"
LOCK_DIR="${KUBECONFIG_PATH}.lock"

mkdir -p "${LOG_DIR}"

refresh_kubeconfig() {
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    sleep 0.2
  done
  python3 "${ROOT_DIR}/scripts/eks_kubeconfig.py" \
    --cluster trino-eks-karpenter \
    --region us-east-1 \
    --output "${KUBECONFIG_PATH}" >/dev/null
  rmdir "${LOCK_DIR}"
}

forward_loop() {
  local name="$1"
  local namespace="$2"
  local service="$3"
  local local_port="$4"
  local remote_port="$5"
  local log_file="${LOG_DIR}/${name}.log"

  while true; do
    refresh_kubeconfig || true
    {
      printf '\n[%s] forwarding %s: localhost:%s -> %s/%s:%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${name}" "${local_port}" "${namespace}" "${service}" "${remote_port}"
      kubectl --kubeconfig "${KUBECONFIG_PATH}" \
        -n "${namespace}" \
        port-forward "svc/${service}" "${local_port}:${remote_port}"
      printf '[%s] %s port-forward exited; restarting\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${name}"
    } >>"${log_file}" 2>&1 || true
    sleep 2
  done
}

forward_loop argocd argocd argocd-server 8080 443 &
forward_loop trino trino trino 8081 8080 &
forward_loop pinot pinot pinot-controller 9000 9000 &

wait
