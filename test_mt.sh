#!/usr/bin/env bash
set -euo pipefail

TA="${TA:-tenant-a}"
TB="${TB:-tenant-b}"
U_A="${U_A:-tenant-a-user}"
U_B="${U_B:-tenant-b-user}"

OK_IMAGE="${OK_IMAGE:-nginx}"
KUBECTL="${KUBECTL:-kubectl}"

# we use "$*" for logging, "$@" for actual calling
info() { echo "[+]" "$*"; }
warn() { echo "[!]" "$*" >&2; }
die() { echo "[xxxx]" "$*" >&2; exit 1; }

run() {
  info "$*"
  "$@"
}

expect_fail() {
  # usage: expect_fail <description> <cmd...>
  local desc="$1"; shift
  info "EXPECT FORBIDDEN: ${desc}"
  # take what the command returns
  if "$@"; then
    die "Did not fail (bad!): ${desc}"
  else
    info "Failed (good!): ${desc}"
  fi
}

# we do set +e because we run commmand that might fail 
cleanup() {
  set +e
  warn "Proceeding to delete everything."

  kubectl config use-context kubernetes-admin@kubernetes >/dev/null 2>&1

  kubectl delete pod --all -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete pod --all -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete configmap cm-a cm-b -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete configmap cm-a cm-b -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete secret secret-a secret-b -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete secret secret-a secret-b -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete rolebinding tenant-a-binding -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete rolebinding tenant-b-binding -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete clusterrole dev --ignore-not-found >/dev/null 2>&1

  kubectl delete namespace "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete namespace "${TB}" --ignore-not-found >/dev/null 2>&1

  info "Deletion completed"
}

trap cleanup EXIT

info "Creating namespaces ${TA}, ${TB}..."
cat <<EOF | "$KUBECTL" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${TA}
  labels:
    tenant: ${TA}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${TB}
  labels:
    tenant: ${TB}
EOF

info "Creating ClusterRole dev..."
cat <<EOF | "$KUBECTL" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "create", "delete"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
EOF

info "Creating RoleBindings to ClusterRole dev for ${U_A} and ${U_B}..."
cat <<EOF | "$KUBECTL" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-binding
  namespace: ${TA}
subjects:
- kind: User
  name: ${U_A}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: dev
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-b-binding
  namespace: ${TB}
subjects:
- kind: User
  name: ${U_B}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: dev
  apiGroup: rbac.authorization.k8s.io
EOF

info "Waiting for RBAC changes to take effect..."
sleep 1

info "=== Expected ALLOWED in ${TA} as ${U_A}: pod read/write/delete ==="
run "$KUBECTL" get pods -n "${TA}" --as="${U_A}"
run "$KUBECTL" run ok-a -n "${TA}" --image="${OK_IMAGE}" --restart=Never --as="${U_A}"
run "$KUBECTL" delete pod ok-a -n "${TA}" --wait=false --ignore-not-found --as="${U_A}"

info "=== Expected ALLOWED in ${TA} as ${U_A}: configmap read/write/delete ==="
run "$KUBECTL" create configmap cm-a -n "${TA}" --from-literal=key=value --as="${U_A}"
run "$KUBECTL" get configmap cm-a -n "${TA}" --as="${U_A}"
run "$KUBECTL" patch configmap cm-a -n "${TA}" --type merge -p '{"data":{"key":"new-value"}}' --as="${U_A}"
run "$KUBECTL" delete configmap cm-a -n "${TA}" --as="${U_A}"

info "=== Expected ALLOWED in ${TA} as ${U_A}: secret admin-sensitive access ==="
run "$KUBECTL" create secret generic secret-a -n "${TA}" --from-literal=token=abc123 --as="${U_A}"
run "$KUBECTL" get secret secret-a -n "${TA}" --as="${U_A}"
run "$KUBECTL" patch secret secret-a -n "${TA}" --type merge -p '{"stringData":{"token":"changed"}}' --as="${U_A}"
run "$KUBECTL" delete secret secret-a -n "${TA}" --as="${U_A}"

info "=== Expected ALLOWED in ${TB} as ${U_B}: varied access attempts ==="
run "$KUBECTL" get pods -n "${TB}" --as="${U_B}"
run "$KUBECTL" create configmap cm-b -n "${TB}" --from-literal=key=value --as="${U_B}"
run "$KUBECTL" get configmap cm-b -n "${TB}" --as="${U_B}"
run "$KUBECTL" create secret generic secret-b -n "${TB}" --from-literal=token=xyz789 --as="${U_B}"
run "$KUBECTL" get secret secret-b -n "${TB}" --as="${U_B}"

info "=== Expected FORBIDDEN cross-tenant access ==="
expect_fail "U_A cannot get pods in ${TB}" \
  "$KUBECTL" get pods -n "${TB}" --as="${U_A}"

expect_fail "U_A cannot create pod in ${TB}" \
  "$KUBECTL" run bad-a -n "${TB}" --image="${OK_IMAGE}" --restart=Never --as="${U_A}"

expect_fail "U_A cannot get secret in ${TB}" \
  "$KUBECTL" get secret secret-b -n "${TB}" --as="${U_A}"

expect_fail "U_B cannot get pods in ${TA}" \
  "$KUBECTL" get pods -n "${TA}" --as="${U_B}"

expect_fail "U_B cannot create configmap in ${TA}" \
  "$KUBECTL" create configmap bad-cm -n "${TA}" --from-literal=key=value --as="${U_B}"

info "All checks completed."