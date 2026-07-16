#!/usr/bin/env bash
# Installs kind (cached), creates a single-node cluster with Calico CNI,
# and applies raw-mode RBAC so Migratowl can manage sandbox pods.

set -euo pipefail

KIND_VERSION="${KIND_VERSION:-v0.32.0}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"
ACTION_PATH="${ACTION_PATH:-}"

log() { echo "[migratowl/start-kind] $*"; }

# ── Install kind ──────────────────────────────────────────────────────────────
if ! command -v kind &>/dev/null; then
  log "Installing kind ${KIND_VERSION}"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *)       echo "Unsupported arch: ${ARCH}" >&2; exit 1 ;;
  esac
  curl -sSfLo /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH_SUFFIX}"
  chmod +x /usr/local/bin/kind
fi
log "kind version: $(kind version)"

# ── Create cluster ────────────────────────────────────────────────────────────
log "Creating kind cluster with Calico CNI config"
kind create cluster \
  --name migratowl \
  --config "${ACTION_PATH}/kind-config.yaml" \
  --wait 120s

# ── Install Calico ────────────────────────────────────────────────────────────
log "Installing Calico ${CALICO_VERSION}"
kubectl apply \
  -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

log "Waiting for Calico pods to be ready (up to 3 min)"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=180s

# ── Apply raw-mode RBAC ───────────────────────────────────────────────────────
log "Applying raw-mode RBAC"
kubectl apply -f - <<'RBAC'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: migratowl
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: migratowl-sandbox-role
  namespace: default
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies"]
    verbs: ["create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: migratowl-sandbox-rolebinding
  namespace: default
subjects:
  - kind: ServiceAccount
    name: migratowl
    namespace: default
roleRef:
  kind: Role
  name: migratowl-sandbox-role
  apiGroup: rbac.authorization.k8s.io
RBAC

log "Cluster ready"
