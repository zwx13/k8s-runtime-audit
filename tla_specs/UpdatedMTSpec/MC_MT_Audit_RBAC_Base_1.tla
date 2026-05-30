---- MODULE MC_MT_Audit_RBAC_Base_1 ----
EXTENDS MT_Audit_RBAC_Base_1

ConstTenantGroups == {"tenant-a-group", "tenant-a-admin", "tenant-b-group", "tenant-b-admin"}
ConstPlatformGroups == {"system-masters"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"namespace1", "namespace2"}
ConstRBNames == {"tenant-a-binding", "tenant-b-binding"}
ConstCRBNames == {"cluster-rb-1", "cluster-admin"}
ConstDefaultClusterRoleNames == {"cluster-admin", "admin", "edit", "view"}
ConstCustomClusterRoleNames == {"dev"}
\* ConstRoleNames == {"ns-dev", "ns-senior-dev"}
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
        IF 
            \/ g = "tenant-a-group"
            \/ g = "tenant-a-admin" 
        THEN "tenant-a"
        ELSE IF 
            \/ g = "tenant-b-group"
            \/ g = "tenant-b-admin"
        THEN "tenant-b"
        ELSE ConstNoTenant
    ]
====
