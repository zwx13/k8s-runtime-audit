---- MODULE MT_Audit_RBAC_Trace_Extended ----
EXTENDS TLC, Json, Sequences, FiniteSets, Naturals, SequencesExt, NatsOps

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
    FailCodes,
    AllocFile
    
VARIABLES
    idx,
    serialized,
    nsTenant,
    roleBindings,
    accessAttempts,
    roleRules,
    allocIn
    

vars == << idx, nsTenant, roleBindings, accessAttempts, roleRules, serialized, allocIn >>

\* utils
SeqToSet(t) == { t[i] : i \in 1..Len(t) }

FunToSeq(f) == SetToSeq({<< k, f[k] >> : k \in DOMAIN f })
\* protect against dupes
SeqToFun(t) == 
  LET T == { t[i] : i \in 1..Len(t) }
      Keys == { pair[1] : pair \in T }
      valuesFor(k) == { pair[2] : pair \in { p \in T : p[1] = k } }
   IN 
    \*  /\ \A p, q \in T : p[1] = q[1] => p[2] = q[2] 
    [ key \in Keys |-> CHOOSE value \in valuesFor(key) : TRUE ]

\* JSON objects will be deserialized to records,
\* and arrays will be deserialized to tuples
\* LogEvents == NatsConsume("audit.multitenancy", "audit-multitenancy-durable")
LogEvents == ndJsonDeserialize(LogFile)

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
RoleRuleVerbs(l) == { v \in SeqToSet(RoleRule1(l)["verbs"]) : TRUE }
RoleRuleResources(l) == { r \in SeqToSet(RoleRule1(l)["resources"]) : TRUE }  \* this is a sequence

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
    /\ TLCSet(13, 0)
    /\ TLCSet(9, 0)
    /\ serialized = FALSE
    /\ allocIn= JsonDeserialize(AllocFile)
    /\  IF DOMAIN allocIn = {} THEN
        /\ nsTenant = [ ns \in NamespacesFromTrace |-> NoTenant ]
        /\ roleBindings = {}
        /\ roleRules = [k \in (NamespacesFromTrace \X RoleNamesFromTrace) |-> {}]
        /\ accessAttempts = {}
      ELSE
        /\ nsTenant = SeqToFun(allocIn.nsTenant)
        /\ roleBindings = SeqToSet(allocIn.roleBindings)
        /\ roleRules = 
            LET rr == SeqToFun(allocIn.roleRules)
            IN [ key \in DOMAIN rr |-> SeqToSet(rr[key]) ]
        /\ accessAttempts = SeqToSet(allocIn.accessAttempts)
        \*  /\ nsTenant = nsT
        \*  /\ roleBindings = rb
        \*  /\ roleRules = rr
        \*  /\ accessAttempts = aa

\* TLC replays (at least when hitting Invariant violatins)
\* this is why we cannot just put the print in Init, or use
\* a variable like `printed = TRUE/FALSE`, it will always start
\* from the beginning. However, this TLCGet/TLCSet strategy seems to
\* work for a whole TLC process
PrintInitOnce ==
    IF TLCGet(13) = 42
      THEN 
      /\ TRUE
      /\ UNCHANGED <<vars>>
      ELSE
      /\ TLCSet(13, 42)
      /\ PrintT("idx=" \o ToString(idx))
      /\ PrintT("init DOMAIN = " \o ToString(DOMAIN allocIn)) 
      /\ PrintT("=============================================") 
      /\ PrintT("init raw = " \o ToString(allocIn)) 
      /\ PrintT("=============================================") 
      /\ PrintT("nsTenant = " \o ToString(nsTenant))
      /\ PrintT("roleBindings = " \o ToString(roleBindings))
      /\ PrintT("roleRules = " \o ToString(roleRules))
      /\ PrintT("accessAttempts = " \o ToString(accessAttempts))
      /\ PrintT("=============================================") 
      /\ UNCHANGED <<vars>>
---------------------------------------------------------------------------------------------
Next ==
  /\ idx <= Len(LogEvents)
  /\ LET l == LogEvents[idx] IN
       IF IsNSCreationLog(l) THEN
         /\ nsTenant' =
              [nsTenant EXCEPT ![NSName(l)] = NSTenantLabel(l)]
         /\ UNCHANGED << roleBindings, accessAttempts, roleRules, serialized, allocIn >>
       ELSE IF IsRoleCreationLog(l) THEN
         /\ roleRules' =
              [roleRules EXCEPT ![ << RoleNameSpace(l), RoleName(l) >> ] = RolePerms(l) ]
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts, serialized, allocIn >>
       ELSE IF IsRBCreationLog(l) THEN
    \*    inversing the "parameters" leads to no corresponding action from the base spec being found
    \* so this actually confirms the approach works
         /\ roleBindings' = roleBindings \cup { << RBSubjectUser(l), RBNamespace(l), RBRole(l) >> }
         /\ UNCHANGED << nsTenant, accessAttempts, roleRules, serialized, allocIn >>
       ELSE IF IsAccessAttemptLog(l) THEN
         /\ accessAttempts' = accessAttempts \cup {<< EffUser(l), TargetNS(l), Verb(l), Resource(l), Code(l) >> }
         /\ UNCHANGED << nsTenant, roleBindings, roleRules, serialized, allocIn >>
       ELSE
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts, roleRules, serialized, allocIn >>
  /\ idx' = idx + 1

\* we serialize and create a JSON object that contains arrays
allocOut ==
  [
    nsTenant |-> FunToSeq(nsTenant),
    roleBindings |-> SetToSeq(roleBindings),
    roleRules |-> FunToSeq([ k \in DOMAIN roleRules |-> SetToSeq(roleRules[k] )]),
    accessAttempts |-> SetToSeq(accessAttempts)
  ]

SerializeAtEnd ==
  /\ idx > Len(LogEvents)
  /\ ~serialized
  /\ serialized' = TRUE
  /\ PrintT("allocOut = " \o ToString(allocOut))
  /\ JsonSerialize(AllocFile, allocOut)
  /\ UNCHANGED << idx, nsTenant, roleBindings, roleRules, accessAttempts, allocIn >>

NextPrintSerialize == Next \/ SerializeAtEnd \/ PrintInitOnce

Model == INSTANCE MT_Audit_RBAC_Base
         WITH Users <- UsersFromTrace,
              Tenants <- TenantsFromTrace,
              Namespaces <- NamespacesFromTrace,
              RoleNames <- RoleNamesFromTrace

TraceBehavior == Init /\ [][NextPrintSerialize]_vars

BaseInv == IF Model!Inv
              THEN TRUE
           ELSE
             IF TLCGet(9) = 42 
               THEN FALSE
               ELSE 
                /\ TLCSet(9, 42)
                /\ PrintT("BaseInv violated at idx=" \o ToString(idx))
                /\ PrintT("allocOut = " \o ToString(allocOut))
                /\ JsonSerialize(AllocFile, allocOut)
                /\ FALSE

\* BaitInv == TLCGet("level") < 14

\* if we set this property in the cfg file,
\* we need to change Init to accept mappings that are not empty
\* in the base spec
BaseSafety == Model!Safety

\* for every step the trace takes, 
\* that step is allowed by the base spec.
\* THEOREM TraceBehavior => Model!Safety

\* all states reached while replaying
\* the trace satisfy the base invariants.
\* THEOREM TraceBehavior => []Model!Inv

=============================================================================