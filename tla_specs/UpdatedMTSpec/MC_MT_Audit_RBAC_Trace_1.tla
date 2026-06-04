---- MODULE MC_MT_Audit_RBAC_Trace_1 ----
EXTENDS MT_Audit_RBAC_Trace_1

ConstTenantGroups == {"tenant-a", "tenant-b"}
ConstPlatformGroups == {"kubeadm:cluster-admins"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"tenant-a", "tenant-b"}
ConstRBNames == {"tenant-a-binding", "tenant-b-binding"}
ConstCRBNames == {"cluster-admin"}
ConstDefaultClusterRoleNames == {"cluster-admin", "admin", "edit", "view"}
ConstCustomClusterRoleNames == {"dev"}
ConstNoTenant == "NO_TENANT"
ConstPermissions == {"none", "read", "write", "admin-powers", "cluster-admin-powers"}

(*
* We define Permissions as being incremental in power.
* cluster-admin-powers > admin-powers > write > read > no-permissions
*)
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
        IF g = "tenant-a"
        THEN "tenant-a"

        ELSE IF g = "tenant-b"
        THEN "tenant-b"

        ELSE ConstNoTenant
    ]
====