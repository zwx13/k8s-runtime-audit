---- MODULE MC_MT_Audit_RBAC_Trace ----
EXTENDS MT_Audit_RBAC_Trace

ConstUsers == {"tenant-a-user", "tenant-b-user", "kubernetes-admin"}
ConstAdmins == {"kubernetes-admin"}
ConstTenants == {"tenant-a", "tenant-b"}
ConstNamespaces == {"tenant-a", "tenant-b"}
ConstVerbs == {"get","list","create"}
ConstResources == {"pods"}
ConstNoTenant == "NO_TENANT"
ConstCodes == {200, 201, 403}
ConstSuccessCodes == {200, 201}
ConstFailCodes == ConstCodes \ ConstSuccessCodes

ConstLogFile == "/home/malina/tla_specs/Toy_MT/trace_nonull.ndjson"

\* ConstAllocFile == "/home/malina/monitoring2k25/mt_spec/allocfile.json"
\* ConstAllocFile == "NONE"

ConstUserTenantMap ==
    [ u \in ConstUsers |->
        IF u = "tenant-a-user" THEN "tenant-a"
        ELSE IF u = "tenant-b-user" THEN "tenant-b"
        ELSE ConstNoTenant
    ]

====