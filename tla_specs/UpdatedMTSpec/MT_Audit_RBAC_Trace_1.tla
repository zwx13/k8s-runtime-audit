---- MODULE MT_Audit_RBAC_Trace_1 ----
EXTENDS Utils, NatsOps

(*************************************************************************)
(* Constants                                                             *)
(*************************************************************************)
CONSTANTS
    TenantGroups, 
    PlatformGroups, 
    Tenants,
    NoTenant, 
    Namespaces, 
    RBNames, 
    CRBNames, 
    DefaultClusterRoleNames, 
    CustomClusterRoleNames, 
    Permissions, 
    PermissionTiers,
    GroupTenantMap, 
    DefaultClusterRolePermMap
    
(*************************************************************************)
(* State variables                                                       *)
(*************************************************************************)
VARIABLES
    idx,
    nsTenantMap,
    roleBindings,
    clusterRoleBindings,
    accessAttempts,
    clusterRoles
    \* rbAlerts,
    \* cbrAlerts,
    \* danglingRBAlerts,
    \* crossTenantAlerts
    

vars == 
    << idx, nsTenantMap, roleBindings, clusterRoleBindings,
    accessAttempts, clusterRoles >>

(*************************************************************************)
(* NatsConsume Call                                                      *)
(*************************************************************************)

(* NatsConsume is idempotent: model checking may
* need to go back and re-run through the actions.
* If this happens, NatsConsume will fetch the same
* batch it fetched before.
* JSON objects will be deserialized to records,
* arrays will be deserialized to tuples
*)
LogEvents == NatsConsume

(*************************************************************************)
(* Access Log Fields                                                     *)
(*************************************************************************)

\* Namespace related
NSName(l) == l["objectRef"]["name"]
NSActorGroup(l) == l["user"]["groups"][1]
NSTenantLabel(l) == l["requestObject"]["metadata"]["labels"]["tenant"]

\* ClusterRole related
\* we take 1st, second is authenticated group
ClusterRoleActorGroup(l) == l["user"]["groups"][1]
ClusterRoleName(l) == l["objectRef"]["name"]
ClusterRolePermission(l) == l["permission"]

\* RoleBinding related
RBActorGroup(l) == l["user"]["groups"][1]
RBNamespace(l) == l["objectRef"]["namespace"]
RBName(l) == l["objectRef"]["name"]
RBTargetGroup(l) == l["requestObject"]["subjects"][1]["name"]
RBClusterRole(l) == l["requestObject"]["roleRef"]["name"]

\* ClusterRoleBindings related
ClusterRBActorGroup(l) == l["user"]["groups"][1]
ClusterRBName(l) == l["objectRef"]["name"]
ClusterRBTargetGroup(l) == l["requestObject"]["subjects"][1]["name"]
ClusterRBClusterRole(l) == l["requestObject"]["roleRef"]["name"]

\* AccessAttempt related
TargetNS(l) == l["objectRef"]["namespace"]
ActorGroup(l) == l["user"]["groups"][1]
Permission(l) == l["permission"]

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

(*************************************************************************)
(* Helpers                                                               *)
(*************************************************************************)

\* Namespace-related
GetAllNSNames(logs) ==
  { NSName(logs[i]) :
      i \in { j \in 1..Len(logs) : (logs[j]["tlaType"] = "ns.created" \/ logs[j]["tlaType"] = "ns.deleted") } }

GetAllNSTenantLabels(logs) ==
  { NSTenantLabel(logs[i]) : 
      i \in { j \in 1..Len(logs) : logs[j]["tlaType"] = "ns.created" } }

\* ClusterRole related
GetAllCustomClusterRoleNames(logs) ==
  { ClusterRoleName(logs[i]) : 
    i \in { j \in 1..Len(logs) : (logs[j]["tlaType"] = "clusterrole.created" \/ logs[j]["tlaType"] = "clusterrole.updated" \/ logs[j]["tlaType"] = "clusterrole.deleted") } }
    
GetAllRBNames(logs) ==
  { RBName(logs[i]) : 
    i \in { j \in 1..Len(logs) : (logs[j]["tlaType"] = "rolebinding.created" \/ logs[j]["tlaType"] = "rolebinding.deleted") } }
      
GetAllClusterRBNames(logs) ==
  { RBName(logs[i]) : 
    i \in { j \in 1..Len(logs) : (logs[j]["tlaType"] = "rolebinding.created" \/ logs[j]["tlaType"] = "rolebinding.deleted") } }
  
\* precompute from logs to avoid creating a constant
\* nsTenantMap and Default CR map are hard-set
\* so are groups (both tenant and platform)
NamespacesFromBatch == GetAllNSNames(LogEvents)
NSTenantLabelsFromBatch == GetAllNSTenantLabels(LogEvents)
RBNamesFromBatch == GetAllRBNames(LogEvents)
ClusterRBNamesFromBatch == GetAllClusterRBNames(LogEvents)
CustomClusterRoleNamesFromBatch == GetAllCustomClusterRoleNames(LogEvents)

\* precomputing from loaded state
AllocIn == NatsLoadCachedState

IsEmpty == DOMAIN AllocIn = {} 

HasEmptyMappings == 
    /\ DOMAIN AllocIn # {}
    /\ \A k \in DOMAIN AllocIn : AllocIn[k] = <<>>

Init == 
    /\ idx = 1
    \* /\ rbAlerts = {}
    \* /\ danglingRBAlerts = {}
    \* /\ crossTenantAlerts = {}
    /\ TLCSet(13, 0)
    /\ PrintT("================================================")
    /\ PrintT("===========Initial State information============")
    /\ PrintT("Length of event batch is: " \o ToString(Len(LogEvents)))
    /\ PrintT("All namespace names in batch: " \o ToString(NamespacesFromBatch))
    /\ PrintT("All ClusterRoleNames in batch: " \o ToString(CustomClusterRoleNamesFromBatch))
    /\ PrintT("All tenant-group names in batch: " \o ToString(NSTenantLabelsFromBatch))
    /\ PrintT("AllocIn is: " \o ToString(AllocIn))
    /\ PrintT("===============================================")
    \* /\ PrintT(LogEvents)
    /\ accessAttempts = [ gnp \in {} |-> {} ]
    /\  IF 
            \/ IsEmpty 
            \/ HasEmptyMappings
        THEN   
            \* if we do not have anywhere to pick up from, we assume cluster is empty
            \* then, initial state is the same as in the base spec
            /\ nsTenantMap = [ ns \in NamespacesFromBatch |-> NoTenant ]
            /\ roleBindings = [nsrb \in {} |-> {}]
            /\ clusterRoleBindings = "cluster-admin" :> <<"system-masters", "cluster-admin">>
            /\ clusterRoles = DefaultClusterRolePermMap
        ELSE
            \* if we have a state to pick up from, we transform it to match the
            \* variables we have defined, then use this as starting point.
            /\ nsTenantMap = SeqToFun(AllocIn.nsTenant)
            /\ clusterRoles = SeqToFun(AllocIn.clusterRoles)
            /\ roleBindings = SeqToFun(AllocIn.roleBindings)
            /\ clusterRoleBindings = SeqToFun(AllocIn.clusterRoleBindings)


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
      /\ PrintT("init raw = " \o ToString(AllocIn)) 
      /\ PrintT("=============================================") 
      /\ UNCHANGED <<vars>>
---------------------------------------------------------------------------------------------
\* this is the edge case when LogEvents is empty but allocIn is not
Model == INSTANCE MT_Audit_RBAC_Base_1
---------------------------------------------------------------------------------------------
Next ==
  /\ idx <= Len(LogEvents)
  /\ PrintT("idx is: " \o ToString(idx))
  /\ PrintT("Event is: " \o ToString(LogEvents[idx]))
  /\ LET l == LogEvents[idx] IN
       IF l["tlaType"] = "ns.created" THEN
         /\ nsTenantMap' =
              [nsTenantMap EXCEPT ![NSName(l)] = NSTenantLabel(l)]
         /\ UNCHANGED << clusterRoles, roleBindings, clusterRoleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "ns.deleted" THEN
         /\ nsTenantMap' =
              [nsTenantMap EXCEPT ![NSName(l)] = NoTenant]
         /\ UNCHANGED << clusterRoles, roleBindings, clusterRoleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "clusterrole.created" THEN
         /\ clusterRoles' = ClusterRoleName(l) :> Permission(l) @@ clusterRoles
         /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "clusterrole.updated" THEN
         /\ clusterRoles' = [clusterRoles EXCEPT ![ClusterRoleName(l)] = Permission(l)]
         /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>
        ELSE IF l["tlaType"] = "clusterrole.deleted" THEN
         /\ clusterRoles' = [key \in DOMAIN clusterRoles \ {ClusterRoleName(l)} |-> clusterRoles[key]]
         /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "rolebinding.created" THEN
         /\ roleBindings' = <<RBNamespace(l), RBName(l)>> :> <<RBTargetGroup(l), RBClusterRole(l)>> @@ roleBindings
         /\ UNCHANGED << nsTenantMap, clusterRoles, clusterRoleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "rolebinding.deleted" THEN
         /\ roleBindings' = [key \in DOMAIN roleBindings \ {<<RBNamespace(l), RBName(l)>>} |-> roleBindings[key]]
         /\ UNCHANGED << nsTenantMap, clusterRoles, clusterRoleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "clusterrolebinding.created" THEN
         /\ clusterRoleBindings' = ClusterRBName(l) :> <<ClusterRBTargetGroup(l), ClusterRoleName(l)>> @@ clusterRoleBindings
         /\ UNCHANGED << nsTenantMap, clusterRoles, roleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "clusterrolebinding.deleted" THEN
         /\ clusterRoleBindings' = [crb \in DOMAIN clusterRoleBindings \ {ClusterRBName(l)} |-> clusterRoleBindings[crb]]
         /\ UNCHANGED << nsTenantMap, clusterRoles, roleBindings, accessAttempts >>
       ELSE IF l["tlaType"] = "access.attempt" THEN
         /\ accessAttempts' = IF <<TargetNS(l), ActorGroup(l), Permission(l)>> \in DOMAIN accessAttempts THEN
                            [accessAttempts EXCEPT ![<<TargetNS(l), ActorGroup(l), Permission(l)>>].respectsNSTMapAtReqTime = (Model!SameTenant(TargetNS(l), ActorGroup(l)) \/ ActorGroup(l) \in PlatformGroups),
                                                   ![<<TargetNS(l), ActorGroup(l), Permission(l)>>].matchingRBorCBR = (Model!MatchRoleBinding(TargetNS(l), ActorGroup(l), Permission(l)) \/ Model!MatchCRBinding(ActorGroup(l), Permission(l)))
                            ]
                              ELSE <<TargetNS(l), ActorGroup(l), Permission(l)>>  :> [ respectsNSTMapAtReqTime |-> (Model!SameTenant(TargetNS(l), ActorGroup(l)) \/ ActorGroup(l) \in PlatformGroups),
                                                                                matchingRBorCBR |-> (Model!MatchRoleBinding(TargetNS(l), ActorGroup(l), Permission(l)) \/ Model!MatchCRBinding(ActorGroup(l), Permission(l)))
                                                                              ] @@ accessAttempts
         /\ UNCHANGED << nsTenantMap, clusterRoles, roleBindings, clusterRoleBindings >>
       ELSE
         /\ UNCHANGED  << nsTenantMap, clusterRoles, roleBindings, clusterRoleBindings >>
  /\ idx' = idx + 1

(*********4ALERTS***********)
\* \* 2do: publish the actual set too
\* AlertIfBindingsBad == 
\*     LET bindingsBad == Model!BadRoleBindings' \ Model!BadRoleBindings IN
\*         IF bindingsBad = {} THEN
\*             /\ PrintT("Good Binding is: " \o ToString(Model!BadRoleBindings'))
\*             /\ TRUE
\*             /\ UNCHANGED << rbAlerts >>
\*         ELSE 
\*             /\ rbAlerts' = rbAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx] >> }
\*             /\ PrintT("AlertedEvents is: " \o ToString(rbAlerts))
\*             /\ PrintT("Bad Binding is: " \o ToString(Model!BadRoleBindings'))
\*             /\ PrintT("Bindingsbad is " \o ToString(bindingsBad))

\* AlertIfCrossTenantBad ==
\*     LET crossTenantBad == Model!BadCrossTenantSuccessSet' \ Model!BadCrossTenantSuccessSet IN
\*         IF crossTenantBad = {} THEN 
\*             /\ TRUE
\*             /\ PrintT("Cross tenant GOOOOD!!!!")
\*             /\ UNCHANGED << crossTenantAlerts >>
\*         ELSE 
\*             /\ crossTenantAlerts' = crossTenantAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
\*             /\ PrintT("Cross tenant bad!!!!")


\* AlertIfDanglingBindings ==
\*     LET danglingBindings == Model!BadDanglingBindingsSet' \ Model!BadDanglingBindingsSet IN
\*         IF danglingBindings = {} THEN
\*             /\ TRUE
\*             /\ PrintT("NOOOOOOOO Dangling binding!!!")
\*             /\ UNCHANGED << danglingRBAlerts >>
\*         ELSE 
\*             /\ danglingRBAlerts' = danglingRBAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
\*             /\ PrintT("Dangling binding!!!")

\* alertOut == rbAlerts \cup crossTenantAlerts \cup danglingRBAlerts
\* (*********4ALERTS***********)

\* AlertIfBadState == AlertIfBindingsBad /\ AlertIfCrossTenantBad /\ AlertIfDanglingBindings

\* we serialize and create a JSON object that contains arrays
allocOut ==
  [
    nsTenant |-> FunToSeq(nsTenantMap),
    clusterRoles |-> FunToSeq(clusterRoles),
    roleBindings |-> FunToSeq(roleBindings),
    clusterRoleBindings |-> FunToSeq(clusterRoleBindings)
  ]

SerializeAtEnd ==
  /\ idx > Len(LogEvents)
  /\ PrintT("Len of events is " \o ToString(Len(LogEvents)))
  /\ PrintT("We are in serialize at end, idx: " \o ToString(idx))
  /\ NatsAckBatch
  /\ PrintT("allocOut = " \o ToString(allocOut))
  /\ NatsPutCachedState(allocOut)
\*   /\ IF alertOut # {} THEN
\*         /\ PrintT("!!! publish alert " \o ToString(Len(LogEvents)))
\*         /\ NatsPublishAlert(SetToSeq(alertOut))
\*      ELSE
\*         /\ PrintT("No alert to publish??????????????? " \o ToString(Len(LogEvents)))
\*         /\ TRUE
  /\ UNCHANGED << vars >>

NextPrintSerialize == Next \/ SerializeAtEnd \/ PrintInitOnce

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


(*************************************************************************)
(* Future Work                                                           *)
(*************************************************************************)
\* if we set this property in the cfg file,
\* we need to change Init to accept mappings that are not empty
\* in the base spec
\* BaseSafety == Model!Safety

\* for every step the trace takes, 
\* that step is allowed by the base spec.
\* THEOREM TraceBehavior => Model!Safety

\* all states reached while replaying
\* the trace satisfy the base invariants.
\* THEOREM TraceBehavior => []Model!Inv

=============================================================================