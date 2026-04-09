---- MODULE MC_MT_Audit_RBAC_Base_1 ----
EXTENDS MT_Audit_RBAC_Base_1

ConstGroups == {"tenant-a-group", "tenant-b-group", "kubernetes-admin"}
ConstClusterAdmins == {"kubernetes-admin"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"namespace1", "namespace2"}
ConstRBNames == {"tenant-a-binding", "tenant-b-binding"}
ConstDefaultClusterRoleNames == {"cluster-admin", "admin", "edit", "view"}
ConstClusterRoleNames == {"dev", "senior-dev"}
ConstVerbs == {"get"}
ConstResources == {"pods"}
ConstNoTenant == "NO_TENANT"

ConstGroupTenantMap ==
    [ g \in ConstGroups |->
        IF g = "tenant-a-group" THEN "tenant-a"
        ELSE IF g = "tenant-b-group" THEN "tenant-b"
        ELSE ConstNoTenant
    ]
====
