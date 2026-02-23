---- MODULE MC_MT_Audit_RBAC_Base ----
EXTENDS MT_Audit_RBAC_Base

ConstUsers == {"tenant-a-user", "tenant-b-user", "kubernetes-admin"}
ConstAdmins == {"kubernetes-admin"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"tenant-a", "tenant-b"}
ConstRBNames == {"tenant-a-binding", "tenant-b-binding"}
ConstRoleNames == {"tenant-basic"}
ConstVerbs == {"get"}
ConstResources == {"pods"}
ConstNoTenant == "NO_TENANT"
ConstCodes == {200, 201, 403}
ConstSuccessCodes == {200, 201}
ConstFailCodes == ConstCodes \ ConstSuccessCodes


ConstUserTenantMap ==
    [ u \in ConstUsers |->
        IF u = "tenant-a-user" THEN "tenant-a"
        ELSE IF u = "tenant-b-user" THEN "tenant-b"
        ELSE ConstNoTenant
    ]
====
