#!/usr/bin/env bash

set -euo pipefail

TENANTS="${1:-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="$SCRIPT_DIR/../../tla_specs/UpdatedMTSpec/MC_MT_Audit_RBAC_Trace_1.tla"

if (( TENANTS < 2 || TENANTS > 10 )); then
    echo "TENANTS must be between 2 and 10" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"

echo "[+] Generating TLA+ model for ${TENANTS} tenants..."
echo "[+] Output: ${OUT}"

tenant_set=""
map_body=""

for n in $(seq 1 "$TENANTS"); do
    tenant="tenant-${n}"

    if [[ -n "$tenant_set" ]]; then
        tenant_set+=", "
    fi

    tenant_set+="\"${tenant}\""

    if [[ -z "$map_body" ]]; then
        map_body="        IF g = \"${tenant}\" THEN \"${tenant}\""
    else
        map_body+=$'\n'"        ELSE IF g = \"${tenant}\" THEN \"${tenant}\""
    fi
done

cat > "$OUT" <<EOF
---- MODULE MC_MT_Audit_RBAC_Trace_1 ----
EXTENDS MT_Audit_RBAC_Trace_1

ConstTenantGroups == {${tenant_set}}

ConstPlatformGroups == {"kubeadm:cluster-admins"}

ConstTenants == {${tenant_set}}

ConstNamespaces == {${tenant_set}}

ConstRBNames == {"tenant-binding"}

ConstCRBNames == {"cluster-admin", "foo-global-binding"}

ConstDefaultClusterRoleNames ==
    {"cluster-admin", "admin", "edit", "view"}

ConstCustomClusterRoleNames == {"dev"}

ConstNoTenant == "NO_TENANT"

ConstPermissions ==
    {"none", "read", "write", "admin-powers", "cluster-admin-powers"}

ConstPermissionTiers ==
    [ p \in ConstPermissions |->
        IF p = "none" THEN 0
        ELSE IF p = "read" THEN 1
        ELSE IF p = "write" THEN 2
        ELSE IF p = "admin-powers" THEN 3
        ELSE 4
    ]

ConstDefaultClusterRolePermMap ==
    [ dk \in ConstDefaultClusterRoleNames |->
        IF dk = "cluster-admin" THEN "cluster-admin-powers"
        ELSE IF dk = "admin" THEN "admin-powers"
        ELSE IF dk = "edit" THEN "write"
        ELSE "read"
    ]

ConstGroupTenantMap ==
    [ g \in ConstTenantGroups |->
${map_body}
        ELSE ConstNoTenant
    ]

====
EOF

echo "Generated $OUT for $TENANTS tenants"