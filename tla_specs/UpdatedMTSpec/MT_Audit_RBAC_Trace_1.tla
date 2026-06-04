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

(* - idx is to iterate through logs incrementally,
*  - the .*Alerts variables are to define sets that contain 
* logs corresponding to cluster state that should not be allowed.
* We cannot use invariants, since the logs may be violating.
* Instead, we follow the cluster's state and alert ONLY ONCE
* per bad audit log.
*)
VARIABLES
    nsTenantMap,
    roleBindings,
    clusterRoleBindings,
    accessAttempts,
    clusterRoles,
    \* variables specific for trace spec
    idx,
    crossTenantAlerts,
    danglingRoleBindingsAlerts,
    danglingClusterRoleBindingsAlerts,
    clusterRoleBindingForTenantAlerts,
    roleBindingToClusterTenantAlerts


vars == 
    << 
        idx, nsTenantMap, clusterRoles, roleBindings, 
        clusterRoleBindings, accessAttempts, crossTenantAlerts, 
        danglingRoleBindingsAlerts, danglingClusterRoleBindingsAlerts,
        clusterRoleBindingForTenantAlerts, roleBindingToClusterTenantAlerts
    >>

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
    i \in { j \in 1..Len(logs) : (logs[j]["tlaType"] = "clusterrolebinding.created" \/ logs[j]["tlaType"] = "clusterrolebinding.deleted") } }
  
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

HasEmptyNSTenantMap ==
    /\ DOMAIN AllocIn # {}
    /\ Len(AllocIn.nsTenant) = 0

Init == 
    /\ idx = 1
    /\ TLCSet(13, 0)
    /\ accessAttempts = [ gnp \in {} |-> {} ]
    /\ crossTenantAlerts = {}
    /\ danglingRoleBindingsAlerts = {}
    /\ danglingClusterRoleBindingsAlerts = {}
    /\ clusterRoleBindingForTenantAlerts = {}
    /\ roleBindingToClusterTenantAlerts = {}
    /\ PrintT("AllocIn is: " \o ToString(AllocIn))
    /\ PrintT("Namespaces from batch: " \o ToString(NamespacesFromBatch))
    /\  
        IF 
            \/ IsEmpty 
            \/ HasEmptyMappings
        THEN   
            \* if we do not have anywhere to pick up from, we assume cluster is empty
            \* then, initial state is the same as in the base spec
            /\ nsTenantMap = [ ns \in Namespaces |-> NoTenant ]
            /\ roleBindings = [nsrb \in {} |-> {}]
            /\ clusterRoleBindings = "cluster-admin" :> <<"kubeadm:cluster-admins", "cluster-admin">>
            /\ clusterRoles = DefaultClusterRolePermMap
        ELSE
            \* if we have a state to pick up from, we transform it to match the
            \* variables we have defined, then use this as starting point.
            /\ nsTenantMap = IF HasEmptyNSTenantMap THEN [ ns \in Namespaces |-> NoTenant ]
                             ELSE SeqToFun(AllocIn.nsTenant)
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
      /\ PrintT("=================================================")
      /\ PrintT("==============Initial State information=================")
      /\ PrintT("Length of event batch is: " \o ToString(Len(LogEvents)))
      /\ PrintT("nsTenantMap is: " \o ToString(nsTenantMap))
      /\ PrintT("clusterRoles is: " \o ToString(clusterRoles))
      /\ PrintT("roleBindings is: " \o ToString(roleBindings))
      /\ PrintT("clusterRoleBindings is: " \o ToString(clusterRoleBindings))
      /\ PrintT("accessAttempts is: " \o ToString(accessAttempts))
      /\ PrintT("All namespace names in batch: " \o ToString(NamespacesFromBatch))
      /\ PrintT("All ClusterRoleNames in batch: " \o ToString(CustomClusterRoleNamesFromBatch))
      /\ PrintT("All RoleBinding names in batch: " \o ToString(RBNamesFromBatch))
      /\ PrintT("All ClusterRoleBinding names in batch: " \o ToString(ClusterRBNamesFromBatch))
      /\ PrintT("All tenant-group names in batch: " \o ToString(NSTenantLabelsFromBatch))
      /\ PrintT("AllocIn is: " \o ToString(AllocIn))
      /\ PrintT("====================================================")
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

AlertIfCrossTenantAction ==
    LET crossTenantAction == Model!CrossTenantSuccessSet' \ Model!CrossTenantSuccessSet IN
        IF crossTenantAction = {} THEN 
            /\ TRUE
            /\ UNCHANGED << crossTenantAlerts >>
        ELSE 
            /\ crossTenantAlerts' = crossTenantAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("!!! Cross Tenant Access Identified !!!")

AlertIfDanglingRoleBindings ==
    LET danglingRoleBindings == Model!DanglingRoleBindingsSet' \ Model!DanglingRoleBindingsSet IN
        IF danglingRoleBindings = {} THEN
            /\ TRUE
            /\ UNCHANGED << danglingRoleBindingsAlerts >>
        ELSE 
            /\ danglingRoleBindingsAlerts' = danglingRoleBindingsAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("!!! Dangling rolebinding identified !!!")

AlertIfDanglingClusterRoleBindings == 
    LET danglingClusterRoleBindings == Model!DanglingRoleBindingsSet' \ Model!DanglingRoleBindingsSet IN
        IF danglingClusterRoleBindings = {} THEN
            /\ TRUE
            /\ UNCHANGED << danglingClusterRoleBindingsAlerts >>
        ELSE 
            /\ danglingClusterRoleBindingsAlerts' = danglingClusterRoleBindingsAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("!!! Dangling clusterrolebinding identified !!!")

AlertIfClusterRoleBindingForTenant ==
    LET clusterRoleBindingForTenant == Model!ClusterRoleBindingForTenantSet' \ Model!ClusterRoleBindingForTenantSet IN
        IF clusterRoleBindingForTenant = {} THEN
            /\ TRUE
            /\ UNCHANGED << clusterRoleBindingForTenantAlerts >>
        ELSE 
            /\ clusterRoleBindingForTenantAlerts' = clusterRoleBindingForTenantAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("!!! ClusterRoleBinding for a tenant group identified !!!")

AlertIfRoleBindingToClusterAdmin ==
    LET roleBindingsToClusterAdmin == Model!RoleBindingToClusterAdminSet' \ Model!RoleBindingToClusterAdminSet IN
        IF roleBindingsToClusterAdmin = {} THEN
            /\ TRUE
            /\ UNCHANGED << roleBindingToClusterTenantAlerts >>
        ELSE 
            /\ roleBindingToClusterTenantAlerts' = roleBindingToClusterTenantAlerts \cup { << LogEvents[idx]["auditID"], LogEvents[idx]["tlaType"] >> }
            /\ PrintT("!!! RoleBinding binding the cluster-admin role identified !!!")

alertOut == crossTenantAlerts \cup danglingRoleBindingsAlerts \cup danglingClusterRoleBindingsAlerts
(*********4ALERTS***********)

AlertIfBadState == AlertIfCrossTenantAction /\ AlertIfDanglingRoleBindings /\ AlertIfDanglingClusterRoleBindings

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
\*   /\ PrintT("We are in serialize at end, idx: " \o ToString(idx))
  /\ NatsAckBatch
  /\ PrintT("allocOut = " \o ToString(allocOut))
  /\ IF alertOut # {} THEN
        /\ PrintT("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        /\ PrintT("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        /\ PrintT("Bad event, alert(s) published in alert stream!")
        /\ PrintT("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        /\ PrintT("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        /\ NatsPublishAlert(SetToSeq(alertOut))
     ELSE
        /\ PrintT("================================================")
        /\ PrintT("In this batch, state of the MT cluster is    ok.")
        /\ PrintT("================================================")
        /\ TRUE
  /\ NatsPutCachedState(allocOut)
  /\ UNCHANGED << vars >>

NextPrintSerialize == PrintInitOnce \/ (Next /\ AlertIfBadState) \/ SerializeAtEnd

TraceBehavior == Init /\ [][NextPrintSerialize]_vars

BaseInv == Model!TypeOK

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