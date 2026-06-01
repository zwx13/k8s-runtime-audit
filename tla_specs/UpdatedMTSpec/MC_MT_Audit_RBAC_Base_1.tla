---- MODULE MC_MT_Audit_RBAC_Base_1 ----
EXTENDS MT_Audit_RBAC_Base_1
CONSTANT namespace1, namespace2

ConstTenantGroups == {"trs", "has"}
ConstPlatformGroups == {"system-masters"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {namespace1, namespace2}
ConstRBNames == {"rb-foo"}
ConstCRBNames == {"cluster-rb-foo", "cluster-admin"}
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
        IF g = "trs"
            \* \/ g = "tenant-a-group"
            \* \/ g = "tenant-a-admin" 
        THEN "tenant-a"
        ELSE IF g = "has"
            \* \/ g = "tenant-b-group"
            \* \/ g = "tenant-b-admin"
        THEN "tenant-b"
        ELSE ConstNoTenant
    ]
====
