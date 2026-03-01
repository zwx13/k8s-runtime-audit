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
\* - create alertedEvents, only send one alert per batch wtih every log

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
    rbAlerts,
    danglingRBAlerts,
    crossTenantAlerts
    

vars == << idx, nsTenant, roleBindings, accessAttempts, roleRules, rbAlerts, danglingRBAlerts, crossTenantAlerts >>

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
      
GetAllRBNames(logs) ==
  { RBName(logs[i]) : 
    i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "rolebinding.created" } }

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
RBNamesFromTrace == GetAllRBNames(LogEvents)
RoleNamesFromTrace == GetAllRoleNames(LogEvents)
TenantsFromTrace == GetAllNSTenants(LogEvents)

\* precomputing from loaded state
AllocIn == NatsLoadCachedState

UsersFromAllocIn ==
    IF DOMAIN AllocIn = {} THEN {} ELSE
      { rb[2] : rb \in SeqToSet(AllocIn.roleBindings) } \cup 
        { aa[1] : aa \in SeqToSet(AllocIn.accessAttempts) }
NamespacesFromAllocIn == IF DOMAIN AllocIn = {} THEN {} ELSE
      DOMAIN SeqToFun(AllocIn.nsTenant)
RBNamesFromAllocIn == IF DOMAIN AllocIn = {} THEN {} ELSE
      { rb[1] : rb \in SeqToSet(AllocIn.roleBindings) }
RoleNamesFromAllocIn == IF DOMAIN AllocIn = {} THEN {} ELSE
      LET rr0 == SeqToFun(AllocIn.roleRules) IN
        { key[2] : key \in DOMAIN rr0 }
TenantsFromAllocIn == IF DOMAIN AllocIn = {} THEN {} ELSE
      { SeqToFun(AllocIn.nsTenant)[ns] : ns \in DOMAIN SeqToFun(AllocIn.nsTenant) }
        
\* create "full" compute of constants
AllUsers == UsersFromTrace \cup UsersFromAllocIn
AllNamespaces == NamespacesFromTrace \cup NamespacesFromAllocIn
AllRBNames == RBNamesFromTrace \cup RBNamesFromAllocIn
AllRoleNames == RoleNamesFromTrace \cup RoleNamesFromAllocIn
AllTenants == TenantsFromTrace \cup TenantsFromAllocIn

IsEmpty == DOMAIN AllocIn = {} 

HasEmptyRecords == 
    /\ DOMAIN AllocIn # {}
    /\ \A k \in DOMAIN AllocIn : AllocIn[k] = <<>>

Init == 
    /\ idx = 1
    /\ rbAlerts = {}
    /\ danglingRBAlerts = {}
    /\ crossTenantAlerts = {}
    /\ TLCSet(13, 0)
    /\ TLCSet(9, 0)
    /\ PrintT("Len of events is " \o ToString(Len(LogEvents)))
    /\ PrintT("Users: " \o ToString(AllUsers))
    /\ PrintT("NS: " \o ToString(AllNamespaces))
    /\ PrintT("RN: " \o ToString(AllRoleNames))
    /\ PrintT("Tenants: " \o ToString(AllTenants))
    \* /\ PrintT(LogEvents)
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
            /\ nsTenant = SeqToFun(AllocIn.nsTenant)
            /\ roleBindings = SeqToSet(AllocIn.roleBindings)
            /\ roleRules = 
                LET rr == SeqToFun(AllocIn.roleRules)
                IN [ key \in DOMAIN rr |-> SeqToSet(rr[key]) ]
            /\ accessAttempts = SeqToSet(AllocIn.accessAttempts)

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
      /\ PrintT("init DOMAIN = " \o ToString(DOMAIN AllocIn)) 
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
\* this is the edge case when LogEvents is empty but allocIn is not
Model == INSTANCE MT_Audit_RBAC_Base
         WITH Users <- AllUsers,
              Tenants <- AllTenants,
              Namespaces <- AllNamespaces,
              RBNames <- AllRBNames,
              RoleNames <- AllRoleNames
---------------------------------------------------------------------------------------------
Next ==
  /\ idx <= Len(LogEvents)
  /\ PrintT("idx is: " \o ToString(idx))
  /\ PrintT("Event is: " \o ToString(LogEvents[idx]))
  /\ LET l == LogEvents[idx] IN
       IF l["tlaType"] = "ns.created" THEN
         /\ nsTenant' =
              [nsTenant EXCEPT ![NSName(l)] = NSTenantLabel(l)]
         /\ UNCHANGED << roleBindings, accessAttempts, roleRules >>
       ELSE IF l["tlaType"] = "ns.deleted" THEN
         /\ nsTenant' =
              [nsTenant EXCEPT ![NSName(l)] = NoTenant]
         /\ UNCHANGED << roleBindings, accessAttempts, roleRules >>
       ELSE IF l["tlaType"] = "role.created" THEN
         /\ roleRules' =
              [roleRules EXCEPT ![ << RoleNameSpace(l), RoleName(l) >> ] = @ \cup RolePerms(l) ]
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "role.deleted" THEN
         /\ roleRules' =
              [roleRules EXCEPT ![ << RoleNameSpace(l), RoleName(l) >> ] = {} ]
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "rolebinding.created" THEN
    \*    inversing the "parameters" leads to no corresponding action from the base spec being found
    \* so this actually confirms the approach works
         /\ roleBindings' = roleBindings \cup { << RBName(l), RBSubjectUser(l), RBNamespace(l), RBRole(l) >> }
         /\ UNCHANGED << nsTenant, accessAttempts, roleRules >>
       ELSE IF l["tlaType"] = "rolebinding.deleted" THEN
         LET rbDelete == CHOOSE rb \in roleBindings : (rb[1] = RBName(l) /\ rb[3] = RBNamespace(l))
         IN
            /\ roleBindings' = roleBindings \ { rbDelete }
            /\ UNCHANGED << nsTenant, accessAttempts, roleRules >>
       ELSE IF l["tlaType"] = "access.attempt" THEN
         /\ accessAttempts' = accessAttempts \cup {<< EffUser(l), TargetNS(l), Verb(l), Resource(l), Code(l), Model!SameTenant(EffUser(l), TargetNS(l)) >> }
         /\ UNCHANGED << nsTenant, roleBindings, roleRules >>
       ELSE
         /\ UNCHANGED << nsTenant, roleBindings, accessAttempts, roleRules >>
  /\ idx' = idx + 1

(*********4ALERTS***********)
\* 2do: publish the actual set too
AlertIfBindingsBad == 
    LET bindingsBad == Model!BadRoleBindings' \ Model!BadRoleBindings IN
        IF bindingsBad = {} THEN
            /\ PrintT("Good Binding is: " \o ToString(Model!BadRoleBindings'))
            /\ TRUE
            /\ UNCHANGED << rbAlerts >>
        ELSE 
            /\ rbAlerts' = rbAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("AlertedEvents is: " \o ToString(rbAlerts))
            /\ PrintT("Bad Binding is: " \o ToString(Model!BadRoleBindings'))
            /\ PrintT("Bindingsbad is " \o ToString(bindingsBad))
            /\ UNCHANGED << danglingRBAlerts, crossTenantAlerts >>

AlertIfCrossTenantBad ==
    LET crossTenantBad == Model!BadCrossTenantSuccessSet' \ Model!BadCrossTenantSuccessSet IN
        IF crossTenantBad = {} THEN 
            /\ TRUE
            /\ UNCHANGED << crossTenantAlerts >>
        ELSE 
            /\ crossTenantAlerts' = crossTenantAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("Cross tenant bad!!!!")
            /\ UNCHANGED << danglingRBAlerts, rbAlerts >>


AlertIfDanglingBindings ==
    LET danglingBindings == Model!BadDanglingBindingsSet' \ Model!BadDanglingBindingsSet IN
        IF danglingBindings = {} THEN
            /\ TRUE
            /\ UNCHANGED << danglingRBAlerts >>
        ELSE 
            /\ danglingRBAlerts' = danglingRBAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("Dangling binding!!!")
            /\ UNCHANGED << crossTenantAlerts, rbAlerts >>

alertOut == rbAlerts \cup crossTenantAlerts \cup danglingRBAlerts
(*********4ALERTS***********)

AlertIfBadState == AlertIfBindingsBad /\ AlertIfCrossTenantBad /\ AlertIfDanglingBindings

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
  /\ PrintT("Len of events is " \o ToString(Len(LogEvents)))
  /\ PrintT("We are in serialize at end, idx: " \o ToString(idx))
  /\ NatsAckBatch
\*   /\ PrintT("allocOut = " \o ToString(allocOut))
  /\ NatsPutCachedState(allocOut)
  /\ IF alertOut # {} THEN 
        NatsPublishAlert(SetToSeq(alertOut))
     ELSE
        TRUE
  /\ UNCHANGED << vars >>

NextPrintSerialize == (Next /\ AlertIfBadState) \/ SerializeAtEnd \/ PrintInitOnce

TraceBehavior == Init /\ [][NextPrintSerialize]_vars

BaseInv == Model!TypeOK

\* BaseInv ==  IF Model!Inv THEN
\*                 TRUE
\*             ELSE
\*                 /\ NatsAckBatch
\*                 /\ NatsPutCachedState(allocOut)
\*                 /\ PrintT("Violation alloc written in " \o ToString(AlertFile))
\*                 /\ FALSE


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