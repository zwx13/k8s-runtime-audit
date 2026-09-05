---- MODULE MC_MT_Audit_RBAC_Trace_1 ----
EXTENDS MT_Audit_RBAC_Trace_1

ConstTenantGroups == {"tenant-1", "tenant-2"}

ConstPlatformGroups == {"kubeadm:cluster-admins"}

ConstTenants == {"tenant-1", "tenant-2"}

ConstNamespaces == {"tenant-1", "tenant-2"}

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
        IF g = "tenant-1" THEN "tenant-1"
        ELSE IF g = "tenant-2" THEN "tenant-2"
        ELSE ConstNoTenant
    ]

====
