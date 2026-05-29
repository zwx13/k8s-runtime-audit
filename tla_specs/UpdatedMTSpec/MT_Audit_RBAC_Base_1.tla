---- MODULE MT_Audit_RBAC_Base_1 ----
EXTENDS Naturals, FiniteSets, TLC, Sequences

(*************************************************************************)
(* Constants                                                             *)
(*************************************************************************)
CONSTANTS TenantGroups, PlatformGroups, Tenants, NoTenant, Namespaces, RBNames, CRBNames, DefaultClusterRoleNames, CustomClusterRoleNames,
Permissions, GroupTenantMap, DefaultClusterRolePermMap

ASSUME GroupTenantMap \in [TenantGroups -> (Tenants \cup {NoTenant})]
ASSUME DefaultClusterRolePermMap \in [DefaultClusterRoleNames -> SUBSET (Permissions)]

(*************************************************************************)
(* Derived constants                                                     *)
(*************************************************************************)
Groups == PlatformGroups \cup TenantGroups

(*************************************************************************)
(* State variables                                                       *)
(*************************************************************************)
VARIABLES nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts, clusterRoles, roles

vars == << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts, clusterRoles, roles >>

(*************************************************************************)
(* Predicates                                                            *)
(*************************************************************************)
MatchRoleBinding(ns, g, p) ==
    \E key \in DOMAIN roleBindings :
        /\ key[1] = ns
        /\ Len(roleBindings[key]) > 0
        /\ g \in roleBindings[key][1]
        /\ p \in clusterRoles[roleBindings[key][2]]

MatchCRBinding(g, p) ==
    \E key \in DOMAIN clusterRoleBindings :
        /\ Len(clusterRoleBindings[key]) # 0
        /\ g \in clusterRoleBindings[key][1]
        /\ p \in clusterRoles[clusterRoleBindings[key][2]]

IsClusterAdmin(actorgroup) ==
    \E key \in DOMAIN clusterRoleBindings:
        /\ Len(clusterRoleBindings[key]) # 0
        \* get system-masters
        /\ actorgroup \in clusterRoleBindings[key][1]
        \* get matching cluster role for "cluster-admin", compare permissions
        /\ clusterRoles[clusterRoleBindings[key][2]] = {"read", "write", "delegate", "escalate", "bind"}

IsNSAdmin(actorgroup, ns) ==
    \E key \in DOMAIN roleBindings:
        /\ key[1] = ns
        /\ roleBindings[key][1] = actorgroup
        /\ clusterRoles[roleBindings[key][2]] = {"read", "write", "delegate"}

IsNSTenant(g) ==
    g \in TenantGroups

SameTenant(ns, g) ==
  /\ IsNSTenant(g)
  /\ nsTenantMap[ns] # NoTenant
  /\ GroupTenantMap[g] = nsTenantMap[ns]

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
      LET subjects == roleBindings[<<ns, rb>>][1]
      IN \A subject \in subjects:
        SameTenant(ns, subject)

(*
* If a group tries to access a tenant that is not theirs,
* the attempt must fail, uness the group is a platform group.
* If that is the case, they have access everywhere.
*)
NoCrossTenantSuccess ==
    \A a \in DOMAIN accessAttempts :
        accessAttempts[a] = TRUE =>
        LET namespace == a[1]
            group == a[2]
        IN 
            \/ SameTenant(namespace, group)
            \/ group \in PlatformGroups

(*
* Cluster admin role should not be given in a ns, 
* since it is too permissive.
*) 
NoClusterAdminRB ==
    \A key \in DOMAIN roleBindings : ~IsClusterAdmin(roleBindings[key][2])

(*
* Tenants should only have access in their namespace, through roleBindings
* => No tenant group should be subject in a cluster roleBinding.
*)
NoTenantCRB ==
    \A key \in DOMAIN clusterRoleBindings : 
        \A g \in clusterRoleBindings[key][1] : 
            ~IsNSTenant(g)

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
  /\ nsTenantMap \in [Namespaces -> (Tenants \cup {NoTenant})]
  /\ DOMAIN roleBindings \in SUBSET (Namespaces \X RBNames)
  /\ \A key \in DOMAIN roleBindings:
        roleBindings[key] \in ( (SUBSET Groups) \X (DefaultClusterRoleNames \cup CustomClusterRoleNames))
  /\ DOMAIN clusterRoleBindings \in SUBSET CRBNames
  /\ \A key \in DOMAIN clusterRoleBindings:
        clusterRoleBindings[key] \in ( (SUBSET (Groups)) \X (DefaultClusterRoleNames \cup CustomClusterRoleNames))
  /\ clusterRoles \in [DefaultClusterRoleNames \cup CustomClusterRoleNames -> SUBSET (Permissions)]
  /\ DOMAIN accessAttempts \in SUBSET (Namespaces \X Groups \X Permissions)
  /\ \A key \in DOMAIN accessAttempts:
        accessAttempts[key] \in BOOLEAN

(*************************************************************************)
(* Initial state                                                         *)
(*************************************************************************)

Init == 
  /\ nsTenantMap = [ns \in Namespaces |-> NoTenant]
  /\ roleBindings = [nsrb \in {} |-> {} ]
  /\ clusterRoleBindings = "cluster-admin" :> <<{"system-masters"}, "cluster-admin">>
  /\ roles = [r \in {} |-> {}]
  /\ clusterRoles = [crName \in CustomClusterRoleNames |-> {}] @@ DefaultClusterRolePermMap
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
    /\ UNCHANGED << roleBindings, clusterRoleBindings, roles, clusterRoles, accessAttempts >>

(*
* Removing the NS-Tenant mapping is abstraction for deleting a NS.
* Whenever we delete a namespace, the rolebindings are deleted, too.
*) 
DeleteNamespace(actorgroup, ns, t) ==
    /\ IsClusterAdmin(actorgroup)
    /\ nsTenantMap[ns] # NoTenant
    /\ roleBindings' = [ rb \in {rb \in DOMAIN roleBindings : rb[1] # ns} |-> roleBindings[rb] ]
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = NoTenant]
    /\ UNCHANGED << clusterRoleBindings, roles, clusterRoles, accessAttempts >>

\* (*
\* * Roles are NS-wide, Cluster-admins can create them.
\* * NS-Admins cannot create roles, but they can
\* * bind approved ones.
\* *)
\* CreateRole(actorgroup, ns, r, p) ==
\*     /\ IsClusterAdmin(actorgroup)
\*     /\ <<ns, r>> \notin DOMAIN roles
\*     /\ roles' = <<ns, r>> :> {p} @@ roles
\*     /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>
    
\* UpdateRole(actorgroup, ns, r, p) ==
\*     /\ IsClusterAdmin(actorgroup)
\*     /\ <<ns, r>> \in DOMAIN roles
\*     /\ roles' = [roles EXCEPT ![<<ns, r>>] = @ \cup {p}]
\*     /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

\* (*
\* * An empty role is different from a fully-deleted role.
\* * Dangling binding points to non-existed role.
\* * If a binding points to an existing empty role, it would just
\* * grant no permissions.
\* *)
\* DeleteRolePermission(actorgroup, ns, r, p) ==
\*     /\ IsClusterAdmin(actorgroup)
\*     /\ <<ns, r>> \in DOMAIN roles
\*     /\ Cardinality(roles[r]) > 1
\*     /\ roles' = [roles EXCEPT ![<<ns, r>>] = @ \ {p}]
\*     /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

\* DeleteRole(actorgroup, ns, r, p) ==
\*     /\ IsClusterAdmin(actorgroup)
\*     /\ <<ns, r>> \in DOMAIN roles
\*     /\ roles' = [key \in DOMAIN roles \ <<ns, r>> |-> roles[key]]
\*     /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

(*
* ClusterRoles are cluster-wide, so they pose a higher risk than roles
* Only the cluster admin creates/updates/deletes these as well.
*)
CreateClusterRole(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ k \in CustomClusterRoleNames
    /\ clusterRoles[k] = {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

UpdateClusterRole(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ k \in CustomClusterRoleNames
    /\ clusterRoles[k] # {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = @ \cup {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

DeleteClusterRolePermission(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ k \in CustomClusterRoleNames
    /\ clusterRoles[k] # {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = @ \ {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

DeleteClusterRole(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ k \in CustomClusterRoleNames
    /\ clusterRoles[k] # {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = {}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

(*
* Access to cluster or namespace is granted through (cluster)roleBindings
* NS access is modified by creating/revoking a roleBinding
* Cluster Access is granted by creating/revoking a clusterRoleBinding
*)
GrantNSAccess(actorgroup, ns, rbName, g, k) ==
    /\ 
        \/ IsClusterAdmin(actorgroup)
        \/ IsNSAdmin(actorgroup, ns)
    /\ SameTenant(g, ns)
    /\ LET clusterPerm == clusterRoles[k]
       IN clusterPerm \in (SUBSET {"read", "write"}) \ {{}}
    /\ roleBindings' = IF <<ns,rbName>> \in DOMAIN roleBindings THEN
                            [roleBindings EXCEPT ![<<ns, rbName>>] = << @[1] \cup {g}, @[2] >>]
                        ELSE <<ns, rbName>> :> <<{g}, k>> @@ roleBindings
    /\ UNCHANGED << nsTenantMap, clusterRoleBindings, clusterRoles, roles, accessAttempts >>

RevokeNSAccess(actorgroup, ns, rbName, g, k) ==
    /\ 
        \/ IsClusterAdmin(actorgroup)
        \* ns admin can only grant as much as they have
        \/ 
            /\ IsNSAdmin(actorgroup, ns)
            /\ k \in {"read", "write"}
    /\ nsTenantMap[ns] # NoTenant
    /\ <<ns, rbName>> \in DOMAIN roleBindings
    /\ roleBindings' = IF Cardinality(roleBindings[<<ns, rbName>>][1]) = 1 THEN
                            [rb \in DOMAIN roleBindings \ {<<ns, rbName>>} |-> roleBindings[rb] ]
                        ELSE [roleBindings EXCEPT ![<<ns, rbName>>] = << @[1] \ {g}, @[2] >>]
    /\ UNCHANGED << nsTenantMap, clusterRoleBindings, clusterRoles, roles, accessAttempts >>

GrantClusterAccess(actorgroup, crbName, g, k) ==
    /\ IsClusterAdmin(actorgroup)
    /\ g \in PlatformGroups
    /\ k \in {"read", "write"}
    /\ clusterRoles[k] # {}
    /\ clusterRoleBindings' = IF crbName \in DOMAIN clusterRoleBindings THEN
                                    [clusterRoleBindings EXCEPT ![crbName] = << @[1] \cup {g}, @[2] >>]
                                ELSE crbName :> <<{g}, k>> @@ clusterRoleBindings
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoles, roles, accessAttempts >>

RevokeClusterAccess(actorgroup, crbName, g, k) ==
    /\ IsClusterAdmin(actorgroup)
    /\ crbName \in DOMAIN clusterRoleBindings
    /\ crbName # "cluster-admin"
    /\ clusterRoleBindings' = IF Cardinality(clusterRoleBindings[crbName][1]) = 1 THEN
                                    [crb \in DOMAIN clusterRoleBindings \ {crbName} |-> clusterRoleBindings[crb]]
                                ELSE [clusterRoleBindings EXCEPT ![crbName] = << @[1] \ g, @[2] >>]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

(*
* We are interested in who can attempt to access what.
* But different access attempts may have different results.
* We update the function in case the result of the access attempt changed.
*)
AttemptedAccess(ns, g, p) ==
  /\ nsTenantMap[ns] # NoTenant
  /\ accessAttempts' = IF <<ns, g, p>> \in DOMAIN accessAttempts THEN
                            [accessAttempts EXCEPT ![<<ns, g, p>>] = (MatchRoleBinding(ns, g, p) \/ MatchCRBinding(g, p))]
                       ELSE <<ns, g, p>>  :> (MatchRoleBinding(ns, g, p) \/ MatchCRBinding(g, p)) @@ accessAttempts
  /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, roles >>


Inv == 
  /\ TypeOK
  /\ BindingsRespectMT
  /\ NoCrossTenantSuccess
  /\ NoClusterAdminRB
  /\ NoTenantCRB

BaitInv == TLCGet("level") < 15

(*************************************************************************)
(* Next states                                                           *)
(*************************************************************************)
Next ==
  \E actorgroup \in Groups, rbName \in RBNames, crbName \in CRBNames, targetgroup \in Groups, ns \in Namespaces, t \in Tenants,
  p \in Permissions, k \in (DefaultClusterRoleNames \cup CustomClusterRoleNames):
    \/ CreateNamespace(actorgroup, ns, t)
    \/ DeleteNamespace(actorgroup, ns, t)
    \* \/ CreateRole(actorgroup, ns, r, p)
    \* \/ UpdateRole(actorgroup, ns, r, p)
    \* \/ DeleteRole(actorgroup, ns, r, p)
    \/ CreateClusterRole(actorgroup, k, p)
    \/ UpdateClusterRole(actorgroup, k, p)
    \/ DeleteClusterRole(actorgroup, k, p)
    \/ GrantNSAccess(actorgroup, ns, rbName, targetgroup, k)
    \/ RevokeNSAccess(actorgroup, ns, rbName, targetgroup, k)
    \/ GrantClusterAccess(actorgroup, crbName, targetgroup, k)
    \/ RevokeClusterAccess(actorgroup, crbName, targetgroup, k)
    \/ AttemptedAccess(ns, targetgroup, p)

(*************************************************************************)
(* Spec                                                                  *)
(*************************************************************************)
Safety == Init /\ [][Next]_vars

=============================================================================
