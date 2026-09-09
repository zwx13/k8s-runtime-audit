---- MODULE MC_MT_Audit_RBAC_Trace_1 ----
EXTENDS MT_Audit_RBAC_Trace_1

ConstTenantGroups == {"tenant-1", "tenant-2", "tenant-3", "tenant-4", "tenant-5", "tenant-6", "tenant-7", "tenant-8", "tenant-9", "tenant-10"}

ConstAdminGroups == {"kubeadm:cluster-admins"}

ConstTenants == {"tenant-1", "tenant-2", "tenant-3", "tenant-4", "tenant-5", "tenant-6", "tenant-7", "tenant-8", "tenant-9", "tenant-10"}

ConstNamespaces == {"tenant-1", "tenant-2", "tenant-3", "tenant-4", "tenant-5", "tenant-6", "tenant-7", "tenant-8", "tenant-9", "tenant-10"}

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
        ELSE IF g = "tenant-3" THEN "tenant-3"
        ELSE IF g = "tenant-4" THEN "tenant-4"
        ELSE IF g = "tenant-5" THEN "tenant-5"
        ELSE IF g = "tenant-6" THEN "tenant-6"
        ELSE IF g = "tenant-7" THEN "tenant-7"
        ELSE IF g = "tenant-8" THEN "tenant-8"
        ELSE IF g = "tenant-9" THEN "tenant-9"
        ELSE IF g = "tenant-10" THEN "tenant-10"
        ELSE ConstNoTenant
    ]

====
