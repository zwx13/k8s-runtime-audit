---- MODULE MC_MT_Audit_RBAC_Base_1 ----
EXTENDS MT_Audit_RBAC_Base_1

ConstGroups == {"tenant-a-group", "tenant-a-admin", "tenant-b-group", "tenant-b-admin", "system-masters"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"namespace1", "namespace2"}
ConstRBNames == {"tenant-a-binding", "tenant-b-binding"}
ConstCRBNames == {"cluster-rb-1", "cluster-admin"}
ConstDefaultClusterRoleNames == {"cluster-admin", "admin", "edit", "view"}
ConstCustomClusterRoleNames == {"dev"}
ConstClusterRoleNames == ConstDefaultClusterRoleNames \cap ConstCustomClusterRoleNames
ConstRoleNames == {"ns-dev", "ns-senior-dev"}
ConstNoTenant == "NO_TENANT"
ConstPermissions == {"read", "write", "bind", "escalate"}

ConstDefaultClusterRolePermMap ==
    [ dk \in ConstDefaultClusterRoleNames |->
        IF dk = "cluster-admin" THEN {"read", "write", "bind", "escalate"} 
        ELSE IF dk = "admin" THEN {"read", "write", "bind"}
        ELSE IF dk = "edit" THEN {"read", "write"}
        ELSE {"read"}
    ]
  
ConstGroupTenantMap ==
    [ g \in ConstGroups |->
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
