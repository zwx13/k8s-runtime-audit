---- MODULE MT_Audit_RBAC_Trace ----
EXTENDS TLC, Json, Sequences, FiniteSets, Naturals, NatsOps

\* 2do: 
\* - handle the tuple case instead of <<v, r>>
\* - add rb revoke
\* - refactor getting fields from logs, since we could reuse the same
\*   function instead of creating separate ones for every allowed action 
\* - decide if we want strict conformance (Next calls exactly the base action) or
\*   if we do observational trace (as we have now, just assignments; then we check Inv?)
\* - fix Is*Log predicate safety; if they reference fields that are missing we will have issues:
\*   The exception was a java.lang.RuntimeException: Attempted to access nonexistent field 'impersonatedUser' of record

\* - refinement on resouces (deletion, configuration)
\* - refinement on roles (can have multiple rules)
\* - refinement on role rules (can have multiple verbs etc)
CONSTANTS
    LogFile,
    Users,
    Tenants,
    NoTenant,
    Namespaces,
    RoleNames,
    Admins,
    Verbs,
    Resources,
    UserTenantMap,
    Codes,
    SuccessCodes,
    FailCodes
    
VARIABLES
    idx,
    nsTenant,
    roleBindings,
    accessAttempts,
    roleRules

vars == << idx, nsTenant, roleBindings, accessAttempts, roleRules >>

\* utils
TupleToSet(t) == { t[i] : i \in 1..Len(t) }

\* JSON objects will be deserialized to records,
\* and arrays will be deserialized to tuples
LogEvents == NatsConsume("audit.multitenancy", "audit-multitenancy-durable")

\* Debug printing of logs
PrintLogStart == PrintT("=== RAW LOG EVENTS ===")
PrintAllLogs  == PrintT(LogEvents)
PrintFirst    == PrintT(LogEvents[1])
PrintSecond   == PrintT(LogEvents[2])
PrintLenLogEvents == PrintT(Len(LogEvents))


\* filter event types by fields
IsNSCreationLog(l) ==
    /\ l["verb"] = "create"
    /\ l["objectRef"]["resource"] = "namespaces"
    /\ l["responseStatus"]["code"] \in SuccessCodes

IsRoleCreationLog(l) ==
    /\ l["verb"] = "create"
    /\ l["objectRef"]["resource"] = "roles"
    /\ l["responseStatus"]["code"] \in SuccessCodes
    
IsRBCreationLog(l) ==
    /\ l["verb"] = "create"
    /\ l["objectRef"]["resource"] = "rolebindings"
    /\ l["responseStatus"]["code"] \in SuccessCodes

\* IsRBDeletionLog(l) ==
\*   /\ ...
    
HasPath(l, k1, k2) == 
  /\ k1 \in DOMAIN l 
  /\ k2 \in DOMAIN l[k1]
  
IsAccessAttemptLog(l) ==
  /\ l["verb"] \in {"create","get","list","delete"}
  /\ l["objectRef"]["resource"] = "pods"
  /\ l["responseStatus"]["code"] \in Codes
  \* must refactor this check
  \* probably handle it with outside filtering
  /\ HasPath(l, "impersonatedUser", "username")
  /\ l["impersonatedUser"]["username"] # "kubernetes-admin"

\* Namespace related
NSName(l) == l["objectRef"]["name"]
NSTenantLabel(l) == l["requestObject"]["metadata"]["labels"]["tenant"]

\* Role related
RoleName(l) == l["objectRef"]["name"]
RoleNameSpace(l) == l["objectRef"]["namespace"]

\* RoleRules related
RoleRule1(l) == l["requestObject"]["rules"][1]

\* make them sets so we can compare and do not get errors like
\* Attempted to check equality of string "get" with non-string: <<"list">>
RoleRuleVerbs(l) == { v \in TupleToSet(RoleRule1(l)["verbs"]) : TRUE }
RoleRuleResources(l) == { r \in TupleToSet(RoleRule1(l)["resources"]) : TRUE }  \* this is a sequence

RolePerms(l) == { << v, r >> : v \in RoleRuleVerbs(l), r \in RoleRuleResources(l) }

\* RoleBinding related
RBNamespace(l) == l["objectRef"]["namespace"]
RBName(l) == l["objectRef"]["name"]
RBSubjectUser(l) == l["requestObject"]["subjects"][1]["name"]
RBRole(l) == l["requestObject"]["roleRef"]["name"]

\* AccessAttempt related
EffUser(l) == l["impersonatedUser"]["username"]
TargetNS(l) == l["objectRef"]["namespace"]
Verb(l) == l["verb"]
Resource(l) == l["objectRef"]["resource"]
Code(l) == l["responseStatus"]["code"]

\* GetAll helpers for initial mapping
(*
We cannot do
GetAllNS(logs) ==
  { NSName(logs[i]) :
      i \in 1..Len(logs) /\ IsNSCreationLog(logs[i]) } }
see https://github.com/tlaplus/rfcs/issues/10
maybe we should check if there s been any update..

Also, we should only "get" constants; getting variables at the
beginning could mess with the creation timestamp and defeat
the spec purpose (e.g. if we get a RB that is created after 
a particular access attempt, we would not know)
*)
GetAllNS(logs) ==
  { NSName(logs[i]) :
      i \in { j \in 1..Len(logs) : IsNSCreationLog(logs[j]) } }

GetAllNSTenants(logs) ==
  { NSTenantLabel(logs[i]) : 
      i \in { j \in 1..Len(logs) : IsNSCreationLog(logs[j]) } }

\* roles should be name mapped to the rules
\* like {<< role-name, ns >> |-> <<verb, resource ]}
GetAllRoleNames(logs) ==
  { RoleName(logs[i]) : 
    i \in { j \in 1..Len(logs) : IsRoleCreationLog(logs[j]) } }

GetAllRBUsers(logs) ==
    {RBSubjectUser(logs[i]) :
     i \in { j \in 1..Len(logs) : IsRBCreationLog(logs[j]) } }      

GetAllAttemptUsers(logs) ==
  { EffUser(logs[i]) :
    i \in { j \in 1..Len(logs) : IsAccessAttemptLog(logs[j]) } }
      
GetAllUsers(logs) ==
    GetAllAttemptUsers(logs) \cup GetAllRBUsers(logs)
  
\* precompute from logs to avoid creating a constant
UsersFromTrace == GetAllUsers(LogEvents)
NamespacesFromTrace == GetAllNS(LogEvents)
RoleNamesFromTrace == GetAllRoleNames(LogEvents)
TenantsFromTrace == GetAllNSTenants(LogEvents)

      
Init == 
    /\ idx = 1
    /\ nsTenant = [ ns \in NamespacesFromTrace |-> NoTenant ]
    /\ accessAttempts = {}
    /\ roleBindings = {}
    /\ roleRules = [k \in (NamespacesFromTrace \X RoleNamesFromTrace) |-> {}]
  /\ PrintLogStart
  /\ PrintAllLogs
  \* /\ PrintFirst
  \* /\ PrintSecond
  /\ PrintLenLogEvents

Next ==
  /\ idx <= Len(LogEvents)
  /\ LET l == LogEvents[idx] IN
       IF IsNSCreationLog(l) THEN
         /\ nsTenant' =
              [nsTenant EXCEPT ![NSName(l)] = NSTenantLabel(l)]
         /\ UNCHANGED << roleBindings, accessAttempts, roleRules >>
       ELSE IF IsRoleCreationLog(l) THEN
         /\ roleRules' =
              [roleRules EXCEPT ![ << RoleNameSpace(l), RoleName(l) >> ] = RolePerms(l) ]
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts >>
       ELSE IF IsRBCreationLog(l) THEN
    \*    inversing the "parameters" leads to no corresponding action from the base spec being found
    \* so this actually confirms the approach works
         /\ roleBindings' = roleBindings \cup { << RBSubjectUser(l), RBNamespace(l), RBRole(l) >> }
         /\ UNCHANGED << nsTenant, accessAttempts, roleRules >>
       ELSE IF IsAccessAttemptLog(l) THEN
         /\ accessAttempts' = accessAttempts \cup {<< EffUser(l), TargetNS(l), Verb(l), Resource(l), Code(l) >> }
         /\ UNCHANGED << nsTenant, roleBindings, roleRules >>
       ELSE
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts, roleRules >>
  /\ idx' = idx + 1

Model == INSTANCE MT_Audit_RBAC_Base
         WITH Users <- UsersFromTrace,
              Tenants <- TenantsFromTrace,
              Namespaces <- NamespacesFromTrace,
              RoleNames <- RoleNamesFromTrace

TraceBehavior == Init /\ [][Next]_vars

BaseInv == Model!Inv
BaseSafety == Model!Safety

\* for every step the trace takes, 
\* that step is allowed by the base spec.
\* THEOREM TraceBehavior => Model!Safety

\* all states reached while replaying
\* the trace satisfy the base invariants.
THEOREM TraceBehavior => []Model!Inv

=============================================================================