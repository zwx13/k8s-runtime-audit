---- MODULE MT_Audit_RBAC_Base_1 ----
EXTENDS Naturals, FiniteSets, TLC, Sequences

(*************************************************************************)
(* Constants                                                             *)
(*************************************************************************)
CONSTANTS 
    TenantGroups, PlatformGroups, Tenants, NoTenant, Namespaces, 
    RBNames, CRBNames, DefaultClusterRoleNames, 
    CustomClusterRoleNames, Permissions, PermissionTiers,
    GroupTenantMap, DefaultClusterRolePermMap

ASSUME GroupTenantMap \in [TenantGroups -> (Tenants \cup {NoTenant})]
ASSUME DefaultClusterRolePermMap \in [DefaultClusterRoleNames -> Permissions]

(*************************************************************************)
(* Derived constants                                                     *)
(*************************************************************************)
Groups == PlatformGroups \cup TenantGroups
ClusterRoleNames == DefaultClusterRoleNames \cup CustomClusterRoleNames

(*************************************************************************)
(* State variables                                                       *)
(*************************************************************************)
VARIABLES 
    nsTenantMap, roleBindings, clusterRoleBindings, 
    accessAttempts, clusterRoles

vars == 
    << nsTenantMap, roleBindings, clusterRoleBindings, 
    accessAttempts, clusterRoles >>

(*************************************************************************)
(* Predicates                                                            *)
(*************************************************************************)

(*
* To have an access attempt be successful in regards to C(RB)s,
* The idea is that the permission corresponding to the ClusterRole
* bound by the C(RB) should be of a >= tier than the one the attempt
* corresponds to
*)
MatchRoleBinding(targetNS, targetG, targetP) ==
    \E key \in DOMAIN roleBindings :
    LET 
        rbRole == roleBindings[key][2]
    IN
        /\ rbRole \in DOMAIN clusterRoles
        /\ LET 
                rbGroups == roleBindings[key][1]
                rbPerms == clusterRoles[rbRole]
                rbNS == key[1]
                rbValue == roleBindings[key]
           IN
                /\ Len(rbValue) # 0
                /\ targetG \in rbGroups
                /\ 
                    \/ targetP = rbPerms
                    \/ PermissionTiers[rbPerms] >= PermissionTiers[targetP]
                /\ rbNS = targetNS

MatchCRBinding(targetG, targetP) ==
    \E key \in DOMAIN clusterRoleBindings :
    LET
        crbRole == clusterRoleBindings[key][2]
    IN
        /\ crbRole \in DOMAIN clusterRoles
        /\ LET
                crbGroups == clusterRoleBindings[key][1]
                crbPerms == clusterRoles[crbRole]
                crbValue == clusterRoleBindings[key]
            IN
                /\ Len(crbValue) # 0
                /\ targetG \in crbGroups
                /\ 
                    \/ targetP = crbPerms
                    \/ PermissionTiers[crbPerms] >= PermissionTiers[targetP]

IsClusterAdmin(actorgroup) ==
    \E key \in DOMAIN clusterRoleBindings:
    LET 
        crbRole == clusterRoleBindings[key][2]
    IN 
        /\ crbRole \in DOMAIN clusterRoles
        /\ LET 
                crbGroups == clusterRoleBindings[key][1]
                crbPerms == clusterRoles[crbRole]
                crbValue == clusterRoleBindings[key]
           IN
                /\ Len(crbValue) # 0
                /\ actorgroup \in crbGroups
                /\ crbPerms = "cluster-admin-powers"

IsNSAdmin(actorgroup, targetNS) ==
    \E key \in DOMAIN roleBindings:
    LET 
        rbRole == roleBindings[key][2]
    IN
        /\ rbRole \in DOMAIN clusterRoles
        /\ LET
                rbGroups == roleBindings[key][1]
                rbPerms == clusterRoles[rbRole]
                rbNS == key[1]
                rbValue == roleBindings[key]
            IN
                /\ Len(rbValue) # 0
                /\ rbNS = targetNS
                /\ actorgroup \in rbGroups
                /\ rbPerms = "admin-powers"

IsNSTenant(g) ==
    g \in TenantGroups

SameTenant(targetNS, targetG) ==
  /\ IsNSTenant(targetG)
  /\ nsTenantMap[targetNS] # NoTenant
  /\ GroupTenantMap[targetG] = nsTenantMap[targetNS]

(*************************************************************************)
(* Invariants                                                            *)
(*************************************************************************)

\* Only Cluster Admins may Create Cluster roles
\* For roles, groups may create roles, but only with permissions they have
\* Any role upgrade is done with Admin approval (aggregation)
\* no escalation/impersonation/binding?
\* only admin group in that ns may be granted admin ns permissions

(*
* For all roleBindings that we have, the tenant of the target subject
* and namespace must match, i.e. there should no binding that binds
* outside the nsTenantMap.
*)
BindingsRespectMT ==
    \A <<ns, rb>> \in DOMAIN roleBindings:
      LET groups == roleBindings[<<ns, rb>>][1]
      IN \A group \in groups:
        SameTenant(ns, group)

(*
* There must be no dangling bindings, as in bindings that bind to a deleted
* ClusterRole; the issue is that a new ClusterRole with the old one's name
* could be created, and it could unintentionally or maliciously
* re-activate the binding.
*)
NoDanglingBindings ==
    \A rbkey \in DOMAIN roleBindings, crbkey \in DOMAIN clusterRoleBindings:
        LET
            rbRole == roleBindings[rbkey][2]
            crbRole == clusterRoleBindings[crbkey][2]
        IN
            /\ rbRole \in DOMAIN clusterRoles
            /\ crbRole \in DOMAIN clusterRoles

(*
* If a group tries to access a tenant that is not theirs,
* the attempt must fail, uness the group is a platform group.
* If that is the case, they have access everywhere.
*)
NoCrossTenantSuccess ==
    \A a \in DOMAIN accessAttempts :
        LET group == a[2]
        IN accessAttempts[a].matchingRBorCBR = TRUE => 
            accessAttempts[a].respectsNSTMapAtReqTime = TRUE

(*
* Cluster admin role should not be given in a ns, 
* since it is too permissive.
*) 
NoClusterAdminRB ==
    \A key \in DOMAIN roleBindings : 
        LET rbGroups == roleBindings[key][1]
        IN 
            ~IsClusterAdmin(rbGroups)

(*
* Tenants should only have access in their namespace, through roleBindings
* => No tenant group should be subject in a cluster roleBinding.
*)
NoTenantCRB ==
    \A key \in DOMAIN clusterRoleBindings : 
        LET crbGroups == clusterRoleBindings[key][1]
        IN 
            \A group \in crbGroups: 
                ~IsNSTenant(group)

\* tenant groups must only have read or write

\* only platform group should have cluster wide max power

\* tenant admins should not be able to give more permissions than they have

(*
* nsTenantMap is equivalent to using NS labels
* a mapping from NS to NoTenant is an abstraction for a non-existing NS
* RBs are NS-scoped; may belong to 1 or more groups, but correspond to max 1 CRName
* a CR is its name mapped to a set of permissions
* an accessAttempt is a function in this base model, since we are not interested in 
repeated attempts; we just want to check that all possible attemps end up ok
*)

TypeOK ==
\*   nsTenantMap
  /\ nsTenantMap \in [Namespaces -> (Tenants \cup {NoTenant})]
\* roleBindings
  /\ DOMAIN roleBindings \in SUBSET (Namespaces \X RBNames)
  /\ \A key \in DOMAIN roleBindings:
        roleBindings[key] \in 
            ((SUBSET Groups) \X ClusterRoleNames)
\* clusterRoleBindings
  /\ DOMAIN clusterRoleBindings \in SUBSET CRBNames
  /\ \A key \in DOMAIN clusterRoleBindings:
        clusterRoleBindings[key] \in 
            ((SUBSET Groups) \X ClusterRoleNames)
\*  clusterRoles 
  /\ DefaultClusterRoleNames \in SUBSET DOMAIN clusterRoles
  /\ DOMAIN clusterRoles \in SUBSET ClusterRoleNames
  /\ \A key \in DOMAIN clusterRoles: 
        clusterRoles[key] \in Permissions
\* accessAttempts
  /\ DOMAIN accessAttempts \in 
        SUBSET (Namespaces \X Groups \X Permissions)
  /\ \A key \in DOMAIN accessAttempts:
        accessAttempts[key] \in [
            respectsNSTMapAtReqTime: BOOLEAN,
            matchingRBorCBR: BOOLEAN
            ]

(*************************************************************************)
(* Initial state                                                         *)
(*************************************************************************)

Init == 
  /\ nsTenantMap = [ns \in Namespaces |-> NoTenant]
  /\ roleBindings = [nsrb \in {} |-> {}]
  /\ clusterRoleBindings = "cluster-admin" :> <<{"system-masters"}, "cluster-admin">>
  /\ clusterRoles = DefaultClusterRolePermMap
  /\ accessAttempts = [ gnp \in {} |-> {} ]


(*************************************************************************)
(* Actions                                                               *)
(*************************************************************************)

(*
* Namespaces with NoTenant are abstractions for non-existent namespaces.
* The creation of a NS involves assigning it to a tenant.
*)
CreateNamespace(actorgroup, ns, t) ==
    /\ IsClusterAdmin(actorgroup)
    /\ nsTenantMap[ns] = NoTenant
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = t]
    /\ UNCHANGED << roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

(*
* Removing the NS-Tenant mapping is abstraction for deleting a NS.
* Whenever we delete a namespace, the rolebindings are deleted, too.
*) 
DeleteNamespace(actorgroup, ns) ==
    /\ IsClusterAdmin(actorgroup)
    /\ nsTenantMap[ns] # NoTenant
    /\ roleBindings' = [ rb \in {rb \in DOMAIN roleBindings : rb[1] # ns} |-> roleBindings[rb] ]
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = NoTenant]
    /\ UNCHANGED << clusterRoleBindings, clusterRoles, accessAttempts >>

(*
* ClusterRoles are cluster-wide permissions.
* Only the cluster admin creates/updates/deletes the custom ones.
* The default ones may not be changed at all.
* 
*)
CreateClusterRole(actorgroup, cr, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ cr \in CustomClusterRoleNames
    /\ cr \notin DOMAIN clusterRoles
    /\ clusterRoles' =  cr :> p @@ clusterRoles
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>

UpdateClusterRole(actorgroup, cr, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ cr \in CustomClusterRoleNames
    /\ cr \in DOMAIN clusterRoles
    /\ clusterRoles' = [clusterRoles EXCEPT ![cr] = p]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>

DeleteClusterRolePermission(actorgroup, cr, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ cr \in CustomClusterRoleNames
    /\ cr \in DOMAIN clusterRoles
    /\ clusterRoles' = 
        IF PermissionTiers[clusterRoles[cr]] = 4 THEN [clusterRoles EXCEPT ![cr] = "admin-powers"]
        ELSE IF PermissionTiers[clusterRoles[cr]] = 3 THEN [clusterRoles EXCEPT ![cr] = "write"]
        ELSE IF PermissionTiers[clusterRoles[cr]] = 3 THEN [clusterRoles EXCEPT ![cr] = "read"]
        ELSE [clusterRoles EXCEPT ![cr] = "none"]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>

(*
* A CR can be deleted no matter if it's empty or if
* It actually has permissionsa associated to it 
*)
DeleteClusterRole(actorgroup, cr) ==
    /\ IsClusterAdmin(actorgroup)
    /\ cr \in CustomClusterRoleNames
    /\ clusterRoles' = [key \in DOMAIN clusterRoles \ {cr} |-> clusterRoles[key]]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts >>

(*
* Access to cluster or namespace is granted through (cluster)roleBindings
* NS access is modified by creating/revoking a roleBinding
* Cluster Access is granted by creating/revoking a clusterRoleBinding
*)

(*
* NSAdmins should be able to only grant access in the namespace where
* they are admins.
*)
GrantNSAccess(actorgroup, targetNS, rbName, targetG, cr) ==
    /\ cr \in DOMAIN clusterRoles
    /\     LET clusterPerm == clusterRoles[cr]
           IN \/ 
                    /\ IsClusterAdmin(actorgroup)
                    /\ clusterPerm \in {"none", "read", "write", "admin-powers"}

              \/ 
                    /\ IsNSAdmin(actorgroup, targetNS)
                    /\ clusterPerm \in {"none", "read", "write"}
                    /\ SameTenant(targetNS, targetG)
    /\ SameTenant(targetNS, targetG)
    /\ roleBindings' = IF <<targetNS,rbName>> \in DOMAIN roleBindings THEN
                            [roleBindings EXCEPT ![<<targetNS, rbName>>] = << @[1] \cup {targetG}, @[2] >>]
                        ELSE <<targetNS, rbName>> :> <<{targetG}, cr>> @@ roleBindings
    /\ UNCHANGED << nsTenantMap, clusterRoleBindings, clusterRoles, accessAttempts >>

(*
* Cluster Admins may remove any rbs anywhere,
* NS Admins should only be able to remove RBs in the NS they're admin in.
* Both should be able to remove dangling bindings, too
*)
RevokeNSAccess(actorgroup, targetNS, rbName, targetG, k) ==
    LET clusterPerm == 
            IF k \in DOMAIN clusterRoles
            THEN clusterRoles[k]
            ELSE "deleted-role"
        rbGroups == roleBindings[<<targetNS, rbName>>][1]
    IN 
        /\
            \/ 
                /\ IsClusterAdmin(actorgroup)
                /\ 
                    \/ clusterPerm = "deleted-role"
                    \/ clusterPerm \in {"none", "read", "write", "admin-powers", "cluster-admin"}
            \/ 
                /\ IsNSAdmin(actorgroup, targetNS)
                /\ 
                    \/ clusterPerm = "deleted-role"
                    \/ clusterPerm \in {"none", "read", "write"}
                /\ SameTenant(targetNS, targetG)
        /\ <<targetNS, rbName>> \in DOMAIN roleBindings
        /\ roleBindings' = IF Cardinality(rbGroups) = 1 THEN
                                [key \in DOMAIN roleBindings \ {<<targetNS, rbName>>} |-> roleBindings[key]]
                            ELSE [roleBindings EXCEPT ![<<targetNS, rbName>>] = << @[1] \ {targetG}, @[2] >>]
        /\ UNCHANGED << nsTenantMap, clusterRoleBindings, clusterRoles, accessAttempts >>

(*
* ClusterAdmins are the only ones who can grant cluster access
* They can only create a clusterRoleBinding that binds a clusterRole
* which already exists. We do not check what permissions they are granting,
* since they can grant whatever they choose to.
*)
GrantClusterAccess(actorgroup, crbName, g, cr) ==
    /\ cr \in DOMAIN clusterRoles
    /\ IsClusterAdmin(actorgroup)
    /\ g \in PlatformGroups
    /\ clusterRoleBindings' = IF crbName \in DOMAIN clusterRoleBindings THEN
                                    [clusterRoleBindings EXCEPT ![crbName] = << @[1] \cup {g}, @[2] >>]
                                ELSE crbName :> <<{g}, cr>> @@ clusterRoleBindings
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoles, accessAttempts >>

(*
* When revoking access, ClusterAdmins may remove whatever they want,
* so we do not even need to check the permissions that are linked to
* the clusterRole bound by the clusterRoleBinding.
*)
RevokeClusterAccess(actorgroup, crbName, g, k) ==
    /\ IsClusterAdmin(actorgroup)
    /\ crbName \in DOMAIN clusterRoleBindings
    /\ crbName # "cluster-admin"
    /\ clusterRoleBindings' = IF Cardinality(clusterRoleBindings[crbName][1]) = 1 THEN
                                    [crb \in DOMAIN clusterRoleBindings \ {crbName} |-> clusterRoleBindings[crb]]
                                ELSE [clusterRoleBindings EXCEPT ![crbName] = << @[1] \ g, @[2] >>]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoles, accessAttempts >>

(*
* We are interested in who can attempt to access what.
* But different access attempts may have different results.
* We update the function in case the result of the access attempt changed.
*)
AttemptedAccess(ns, g, p) ==
  /\ nsTenantMap[ns] # NoTenant
  /\ accessAttempts' = IF <<ns, g, p>> \in DOMAIN accessAttempts THEN
                            [accessAttempts EXCEPT ![<<ns, g, p>>].respectsNSTMapAtReqTime = (SameTenant(ns, g) \/ g \in PlatformGroups),
                                                   ![<<ns, g, p>>].matchingRBorCBR = (MatchRoleBinding(ns, g, p) \/ MatchCRBinding(g, p))
                            ]
                       ELSE <<ns, g, p>>  :> [ respectsNSTMapAtReqTime |-> (SameTenant(ns, g) \/ g \in PlatformGroups),
                                               matchingRBorCBR |-> (MatchRoleBinding(ns, g, p) \/ MatchCRBinding(g, p))
                                             ] @@ accessAttempts
  /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles >>


Inv ==
  /\ TypeOK
\*   /\ BindingsRespectMT
\*   /\ NoCrossTenantSuccess
\*   /\ NoClusterAdminRB
\*   /\ NoTenantCRB

BaitInv == TLCGet("level") < 15

(*************************************************************************)
(* Next states                                                           *)
(*************************************************************************)
Next ==
  \E actorgroup \in Groups, rbName \in RBNames, crbName \in CRBNames, 
    targetgroup \in Groups, ns \in Namespaces, t \in Tenants,
    p \in Permissions, cr \in (ClusterRoleNames):
        \/ CreateNamespace(actorgroup, ns, t)
        \/ DeleteNamespace(actorgroup, ns)
        \/ CreateClusterRole(actorgroup, cr, p)
        \/ UpdateClusterRole(actorgroup, cr, p)
        \/ DeleteClusterRolePermission(actorgroup, cr, p)
        \/ DeleteClusterRole(actorgroup, cr)
        \/ GrantNSAccess(actorgroup, ns, rbName, targetgroup, cr)
        \/ RevokeNSAccess(actorgroup, ns, rbName, targetgroup, cr)
        \/ GrantClusterAccess(actorgroup, crbName, targetgroup, cr)
        \/ RevokeClusterAccess(actorgroup, crbName, targetgroup, cr)
        \/ AttemptedAccess(ns, targetgroup, p)

(*************************************************************************)
(* Spec                                                                  *)
(*************************************************************************)
Safety == Init /\ [][Next]_vars

=============================================================================
