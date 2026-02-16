---- MODULE MT_Audit_RBAC_Trace_Extended ----
EXTENDS Utils, NatsOps

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
    AllocFile,
    AlertFile
    
VARIABLES
    idx,
    nsTenant,
    roleBindings,
    accessAttempts,
    roleRules,
    allocIn
    

vars == << idx, nsTenant, roleBindings, accessAttempts, roleRules, allocIn >>

\* JSON objects will be deserialized to records,
\* and arrays will be deserialized to tuples
LogEvents == NatsConsume
\* LogEvents == ndJsonDeserialize(LogFile)

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
      i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "ns.created" } }

GetAllNSTenants(logs) ==
  { NSTenantLabel(logs[i]) : 
      i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "ns.created" } }

\* roles should be name mapped to the rules
\* like {<< role-name, ns >> |-> <<verb, resource ]}
GetAllRoleNames(logs) ==
  { RoleName(logs[i]) : 
    i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "role.created" } }

GetAllRBUsers(logs) ==
    {RBSubjectUser(logs[i]) :
     i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "rolebinding.created" } }      

GetAllAttemptUsers(logs) ==
  { EffUser(logs[i]) :
    i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "access.attempt" } }
      
GetAllUsers(logs) ==
    GetAllAttemptUsers(logs) \cup GetAllRBUsers(logs)
  
\* precompute from logs to avoid creating a constant
UsersFromTrace == GetAllUsers(LogEvents)
NamespacesFromTrace == GetAllNS(LogEvents)
RoleNamesFromTrace == GetAllRoleNames(LogEvents)
TenantsFromTrace == GetAllNSTenants(LogEvents)

IsEmpty == DOMAIN allocIn = {}

HasEmptyRecords == 
    /\ DOMAIN allocIn # {}
    /\ \A k \in DOMAIN allocIn : allocIn[k] = <<>>

Init == 
    /\ idx = 1
    /\ TLCSet(13, 0)
    /\ TLCSet(9, 0)
    /\ PrintT(LogEvents)
    /\ PrintT("Users from Trace: " \o ToString(UsersFromTrace))
    /\ PrintT("NS from Trace: " \o ToString(NamespacesFromTrace))
    /\ PrintT("RN from Trace: " \o ToString(RoleNamesFromTrace))
    /\ PrintT("Tenants from Trace: " \o ToString(TenantsFromTrace))
    /\ PrintT(LogEvents)
    /\ allocIn = NatsLoadCachedState
    \* /\ PrintT("allocIn is: " \o ToString(allocIn))
    /\  IF 
          \/ IsEmpty 
          \/ HasEmptyRecords
        THEN    
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
    \*   /\ PrintT("init raw = " \o ToString(allocIn)) 
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
  /\ PrintT("idx is: " \o ToString(idx))
  /\ LET l == LogEvents[idx] IN
       IF l["tlaType"] = "ns.created" THEN
         /\ nsTenant' =
              [nsTenant EXCEPT ![NSName(l)] = NSTenantLabel(l)]
         /\ UNCHANGED << roleBindings, accessAttempts, roleRules, allocIn >>
       ELSE IF l["tlaType"] = "role.created" THEN
         /\ roleRules' =
              [roleRules EXCEPT ![ << RoleNameSpace(l), RoleName(l) >> ] = RolePerms(l) ]
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts, allocIn >>
       ELSE IF l["tlaType"] = "rolebinding.created" THEN
    \*    inversing the "parameters" leads to no corresponding action from the base spec being found
    \* so this actually confirms the approach works
         /\ roleBindings' = roleBindings \cup { << RBSubjectUser(l), RBNamespace(l), RBRole(l) >> }
         /\ UNCHANGED << nsTenant, accessAttempts, roleRules, allocIn >>
       ELSE IF l["tlaType"] = "access.attempt" THEN
         /\ accessAttempts' = accessAttempts \cup {<< EffUser(l), TargetNS(l), Verb(l), Resource(l), Code(l) >> }
         /\ UNCHANGED << nsTenant, roleBindings, roleRules, allocIn >>
       ELSE
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts, roleRules, allocIn >>
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
  /\ NatsAckBatch
  /\ PrintT("allocOut = " \o ToString(allocOut))
  /\ NatsPutCachedState(allocOut)
  /\ UNCHANGED << idx, nsTenant, roleBindings, roleRules, accessAttempts, allocIn >>

NextPrintSerialize == Next \/ SerializeAtEnd \/ PrintInitOnce

\* this is the edge case when LogEvents is empty but allocIn is not
Model == INSTANCE MT_Audit_RBAC_Base
         WITH Users <- UsersFromTrace,
              Tenants <- TenantsFromTrace,
              Namespaces <- NamespacesFromTrace,
              RoleNames <- RoleNamesFromTrace

TraceBehavior == Init /\ [][NextPrintSerialize]_vars

\* BaseInv == Model!Inv

BaseInv ==  IF Model!Inv THEN
                TRUE
            ELSE
                /\ NatsAckBatch
                /\ NatsPutCachedState(allocOut)
                /\ PrintT("Violation alloc written in " \o ToString(AlertFile))
                /\ FALSE


\* BaseInv == Model!Inv

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