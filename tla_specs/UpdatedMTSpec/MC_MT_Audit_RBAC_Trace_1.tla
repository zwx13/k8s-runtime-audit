---- MODULE MC_MT_Audit_RBAC_Trace_1 ----
EXTENDS MT_Audit_RBAC_Trace_1

(*
* These should be changed to match the tenant names and the
* rest of the objects in the cluster. The python/python_audit/mt_state_bootstrap.py
* should be modified as well, in order to match the entities in the cluster.
* Otherwise, TLC will fail when it ingests logs that reference something that is not
* one of the entries of these constants.
*)
ConstTenantGroups == {"tenant-a", "tenant-b"}
ConstPlatformGroups == {"kubeadm:cluster-admins"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"tenant-a", "tenant-b"}
ConstRBNames == {"tenant-a-binding", "tenant-b-binding"}
ConstCRBNames == {"cluster-admin", "foo-global-binding"}
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

(*
* FUTURE WORK: find a mechanism that avoids requiring
* to hardcode object names in this MC.*.tla file
*)

====