---- MODULE MT_Audit_RBAC_Base_1 ----
EXTENDS Naturals, FiniteSets, TLC, Sequences

CONSTANTS TenantGroups, PlatformGroups, Tenants, NoTenant, Namespaces, RBNames, CRBNames, RoleNames, DefaultClusterRoleNames,
Permissions, GroupTenantMap, DefaultClusterRolePermMap

ASSUME GroupTenantMap \in [TenantGroups -> (Tenants \cup {NoTenant})]
ASSUME DefaultClusterRolePermMap \in [DefaultClusterRoleNames -> SUBSET (Permissions)]

VARIABLES nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts, clusterRoles, roles

vars == << nsTenantMap, roleBindings, clusterRoleBindings, accessAttempts, clusterRoles, roles >>
Groups == PlatformGroups \cup TenantGroups
(************************Predicates START****************************)
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
(************************Predicates END****************************)


(*************************Invariants START*************************)
\* Only Cluster Admins may Create Cluster roles
\* For roles, groups may create roles, but only with permissions they have
\* Any role upgrade is done with Admin approval (aggregation)
\* no escalation/impersonation/binding?
\* only admin group in that ns may be granted admin ns permissions

BindingsRespectMT ==
    \A <<ns, rb>> \in DOMAIN roleBindings:
      LET subjects == roleBindings[<<ns, rb>>][1]
      IN \A subject \in subjects:
        SameTenant(ns, subject)

NoCrossTenantSuccess ==
    \A a \in DOMAIN accessAttempts :
        accessAttempts[a] = TRUE =>
        LET namespace == a[1]
            group == a[2]
        IN \/ SameTenant(namespace, group)
           \/ group \in PlatformGroups

\* cluster admin role should not be given in a ns, too many permissions
NoClusterAdminRB ==
    \A key \in DOMAIN roleBindings : ~IsClusterAdmin(roleBindings[key][2])

\* tenants should only have access in their namespace
\* no tenant group should be in a cluste role binding
NoTenantCRB ==
    \A key \in DOMAIN clusterRoleBindings : 
        \A g \in clusterRoleBindings[key][1] : 
            ~IsNSTenant(g)

\* tenant groups must only have read or write
\* NoTenantSuperPermissions ==
\*     \A 

\* only platform group should have cluster wide max power

\* tenant admins should not be able to give more permissions than they have

(*** nsTenantMap is equivalent to using NS labels ***)
(*** a mapping from NS to NoTenant is an abstraction for a non-existing NS ***)
(*** RBs are NS-scoped; may belong to 1 or more groups, but correspond to max 1 CRName ***)
(*** a CR is its name mapped to a set of permissions ***)
(*** an accessAttempt is a function in this base model, since we are not interested in 
     repeated attempts; we just want to check that all possible attemps end up ok ***)
TypeOK ==
  /\ nsTenantMap \in [Namespaces -> (Tenants \cup {NoTenant})]
  /\ DOMAIN roleBindings \in SUBSET (Namespaces \X RBNames)
  /\ \A key \in DOMAIN roleBindings:
        roleBindings[key] \in ( (SUBSET Groups) \X DefaultClusterRoleNames)
  /\ DOMAIN clusterRoleBindings \in SUBSET CRBNames
  /\ \A key \in DOMAIN clusterRoleBindings:
        clusterRoleBindings[key] \in ( (SUBSET (Groups)) \X DefaultClusterRoleNames)
  /\ DOMAIN roles \in SUBSET (Namespaces \X RoleNames)
  /\ \A key \in DOMAIN roles:
        roles[key] \in SUBSET (Permissions \cup {})
  /\ clusterRoles \in [DefaultClusterRoleNames -> SUBSET (Permissions \cup {})]
  /\ DOMAIN accessAttempts \in SUBSET (Namespaces \X Groups \X Permissions)
  /\ \A key \in DOMAIN accessAttempts:
        accessAttempts[key] \in BOOLEAN
(*************************Invariants END*************************)

(*************************Initial State START*************************)
Init == 
  /\ nsTenantMap = [ns \in Namespaces |-> NoTenant]
  /\ roleBindings = [nsrb \in {} |-> {} ]
  /\ clusterRoleBindings = "cluster-admin" :> <<{"system-masters"}, "cluster-admin">>
  /\ roles = [r \in {} |-> {}]
\*   /\ clusterRoles = [k \in DefaultClusterRoleNames |-> {} ]
  /\ clusterRoles = DefaultClusterRolePermMap
  /\ accessAttempts = [ gnp \in {} |-> {} ]
(*************************Initial State END*************************)


(*************************Allowed Actions START*************************)

(*** Namespaces with NoTenant are abstractions for non-existent namespaces ***)
(*** The creation of a NS involves assigning it to a tenant ***)
CreateNamespace(actorgroup, ns, t) ==
    /\ IsClusterAdmin(actorgroup)
    /\ nsTenantMap[ns] = NoTenant
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = t]
    /\ UNCHANGED << roleBindings, clusterRoleBindings, roles, clusterRoles, accessAttempts >>

(*** Removing the NS, Tenant mapping is abstraction for deleting a NS ***)
DeleteNamespace(actorgroup, ns, t) ==
    /\ IsClusterAdmin(actorgroup)
    /\ nsTenantMap[ns] # NoTenant
    /\ roleBindings' = [ rb \in {rb \in DOMAIN roleBindings : rb[1] # ns} |-> roleBindings[rb] ]
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = NoTenant]
    /\ UNCHANGED << clusterRoleBindings, roles, clusterRoles, accessAttempts >>

(*** Roles are NS-wide, NS-admins can create them ***)
CreateRole(actorgroup, g, ns, r, p) ==
    /\ SameTenant(g, ns)
    /\ IsNSAdmin(actorgroup, ns)
    /\ <<ns, r>> \notin DOMAIN roles
    /\ roles' = <<ns, r>> :> {p} @@ roles
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>
    
UpdateRole(actorgroup, g, ns, r, p) ==
    /\ SameTenant(g, ns)
    /\ IsNSAdmin(actorgroup, ns)
    /\ <<ns, r>> \in DOMAIN roles
    /\ roles' = [roles EXCEPT ![<<ns, r>>] = @ \cup {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

DeleteRolePermission(actorgroup, g, ns, r, p) ==
    /\ SameTenant(g, ns)
    /\ IsNSAdmin(actorgroup, ns)
    /\ <<ns, r>> \in DOMAIN roles
    /\ Cardinality(roles[r]) > 1
    /\ roles' = [roles EXCEPT ![<<ns, r>>] = @ \ {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

DeleteRole(actorgroup, g, ns, r, p) ==
    /\ SameTenant(g, ns)
    /\ IsNSAdmin(actorgroup, ns)
    /\ <<ns, r>> \in DOMAIN roles
    /\ roles' = [key \in DOMAIN roles \ <<ns, r>> |-> roles[key]]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, accessAttempts >>

(*** ClusterRoles are cluster-wide, the admin creates them ***)
CreateClusterRole(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ clusterRoles[k] = {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

(*** ClusterRoles may be modified: Admins may add permissions to them ***)
UpdateClusterRole(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = @ \cup {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

(*** We can also delete CR individual perms ***)
DeleteClusterRolePermission(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ clusterRoles[k] # {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = @ \ {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

(*** ClusterRole deletion implies removing the value of the mapping ***)
DeleteClusterRole(actorgroup, k, p) ==
    /\ IsClusterAdmin(actorgroup)
    /\ clusterRoles[k] # {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = {}]
    /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, roles, accessAttempts >>

(*** NS access is modified by creating/revoking a roleBinding ***)
GrantNSAccess(actorgroup, ns, rbName, g, k) ==
    /\ 
        \/ IsClusterAdmin(actorgroup)
        \/ IsNSAdmin(actorgroup, ns)
    /\ SameTenant(g, ns)
    /\ clusterRoles[k] # {}
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

(*** Cluster Access is granted by creating/revoking a clusterRoleBinding ***)
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

(*** Track all accessAttempts ***)
AttemptedAccess(ns, g, p) ==
  /\ nsTenantMap[ns] # NoTenant
  /\ accessAttempts' = IF <<ns, g, p>> \in DOMAIN accessAttempts THEN
                            [accessAttempts EXCEPT ![<<ns, g, p>>] = (MatchRoleBinding(ns, g, p) \/ MatchCRBinding(g, p))]
                       ELSE <<ns, g, p>>  :> (MatchRoleBinding(ns, g, p) \/ MatchCRBinding(g, p)) @@ accessAttempts
  /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoleBindings, clusterRoles, roles >>

(*************************Allowed Actions END*************************)

Inv == 
  /\ TypeOK
  /\ BindingsRespectMT
  /\ NoCrossTenantSuccess
  /\ NoClusterAdminRB
  /\ NoTenantCRB

BaitInv == TLCGet("level") < 15

Next ==
  \E actorgroup \in Groups, rbName \in RBNames, crbName \in CRBNames, targetgroup \in Groups, ns \in Namespaces, t \in Tenants,
  p \in Permissions, k \in DefaultClusterRoleNames:
    \/ CreateNamespace(actorgroup, ns, t)
    \/ DeleteNamespace(actorgroup, ns, t)
    \* \/ CreateRole
    \* \/ UpdateRole
    \* \/ DeleteRole
    \* \/ CreateNetworkPolicy
    \* \/ UpdateNetworkPolicy
    \* \/ RevokeNetworkPolicy
    \/ CreateClusterRole(actorgroup, k, p)
    \/ UpdateClusterRole(actorgroup, k, p)
    \/ DeleteClusterRole(actorgroup, k, p)
    \/ GrantNSAccess(actorgroup, ns, rbName, targetgroup, k)
    \/ RevokeNSAccess(actorgroup, ns, rbName, targetgroup, k)
    \/ GrantClusterAccess(actorgroup, crbName, targetgroup, k)
    \/ RevokeClusterAccess(actorgroup, crbName, targetgroup, k)
    \/ AttemptedAccess(ns, targetgroup, p)

Safety == Init /\ [][Next]_vars

=============================================================================
