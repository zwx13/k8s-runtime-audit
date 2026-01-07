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
    die "Expected failure but command succeeded: ${desc}"
  else
    info "PASS (failed as expected): ${desc}"
  fi
}

# we do set +e because we run commmand that might fail 
cleanup() {
  set +e
  warn "Proceeding to delete everything."

  kubectl config use-context kubernetes-admin@kubernetes >/dev/null 2>&1

  kubectl delete pod --all -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete pod --all -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete rolebinding tenant-a-binding -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete rolebinding tenant-b-binding -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete role tenant-basic -n "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete role tenant-basic -n "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl delete namespace "${TA}" --ignore-not-found >/dev/null 2>&1
  kubectl delete namespace "${TB}" --ignore-not-found >/dev/null 2>&1

  kubectl get ns "${TA}" "${TB}" >/dev/null 2>&1 || true

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

info "Creating Roles (tenant-basic) in both namespaces..."
cat <<EOF | "$KUBECTL" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-basic
  namespace: ${TA}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-basic
  namespace: ${TB}
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","create"]
EOF

info "Creating RoleBindings for ${U_A} (in ${TA}) and ${U_B} (in ${TB})..."
cat <<EOF | "$KUBECTL" apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-binding
  namespace: ${TA}
subjects:
- kind: User
  name: ${U_A}
roleRef:
  kind: Role
  name: tenant-basic
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
roleRef:
  kind: Role
  name: tenant-basic
  apiGroup: rbac.authorization.k8s.io
EOF

info "Waiting for RBAC changes to take effect (1 sec delay)"
sleep 1

info "=== Expected ALLOWED in ${TA} as ${U_A} ==="
run "$KUBECTL" get pods -n "${TA}" --as="${U_A}"
run "$KUBECTL" run ok-a -n "${TA}" --image="${OK_IMAGE}" --restart=Never --as="${U_A}"

info "=== Expected FORBIDDEN in ${TB} as ${U_A} ==="
expect_fail "kubectl get pods -n ${TB} --as=${U_A}" "$KUBECTL" get pods -n "${TB}" --as="${U_A}"
expect_fail "kubectl run bad-a -n ${TB} --as=${U_A}" "$KUBECTL" run bad-a -n "${TB}" --image="${OK_IMAGE}" --restart=Never --as="${U_A}"

info "All checks completed."

