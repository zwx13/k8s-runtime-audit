---- MODULE MT_Audit_RBAC_Base_1 ----
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Groups, Tenants, NoTenant, Namespaces, RBNames, ClusterRoleNames,
 ClusterAdmins, Verbs, Resources, GroupTenantMap

ASSUME ClusterAdmins \subseteq Groups
ASSUME \A a \in ClusterAdmins : GroupTenantMap[a] = NoTenant
ASSUME GroupTenantMap \in [Groups -> (Tenants \cup {NoTenant})]
VARIABLES nsTenantMap, roleBindings, accessAttempts, clusterRoles

vars == << nsTenantMap, roleBindings, accessAttempts, clusterRoles >>

(*** Permissions are sets of tuples ***)
Permissions == Verbs \X Resources

MatchRoleBinding(g, ns, p) ==
    \E key \in DOMAIN roleBindings :
        /\ key[1] = ns
        /\ roleBindings[key] # {}
        /\ g \in roleBindings[key][1]
        /\ p \in clusterRoles[roleBindings[key][2]]

SameTenant(g, ns) ==
  /\ nsTenantMap[ns] # NoTenant
  /\ GroupTenantMap[g] = nsTenantMap[ns]


BindingsRespectMT ==
    \A rbName \in RBNames, g \in Groups, ns \in Namespaces :
      <<ns, rbName>> \in DOMAIN roleBindings => SameTenant(g, ns)

NoCrossTenantSuccess ==
    \A a \in DOMAIN accessAttempts :
        accessAttempts[a] = TRUE => SameTenant(a[1], a[2])

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
        roleBindings[key] \in ( (SUBSET Groups) \X ClusterRoleNames)
  /\ clusterRoles \in [ClusterRoleNames -> SUBSET (Permissions \cup {})]
  /\ DOMAIN accessAttempts \in SUBSET (Namespaces \X Groups \X Permissions)
  /\ \A key \in DOMAIN accessAttempts:
        accessAttempts[key] \in BOOLEAN    
Init == 
  /\ nsTenantMap = [ns \in Namespaces |-> NoTenant]
  /\ roleBindings = [nsrb \in {} |-> {} ]
  /\ clusterRoles = [k \in ClusterRoleNames |-> {} ]
  /\ accessAttempts = [ gnp \in {} |-> {} ]

(*** Namespaces with NoTenant are abstractions for non-existent namespaces ***)
(*** The creation of a NS involves assigning it to a tenant ***)
CreateNamespace(actor, ns, t) ==
    /\ actor \in ClusterAdmins
    /\ nsTenantMap[ns] = NoTenant
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = t]
    /\ UNCHANGED << roleBindings, accessAttempts, clusterRoles >>

(*** Removing the NS, Tenant mapping is abstraction for deleting a NS ***)
DeleteNamespace(actor, ns, t) ==
    /\ actor \in ClusterAdmins
    /\ nsTenantMap[ns] # NoTenant
    /\ nsTenantMap' = [nsTenantMap EXCEPT ![ns] = NoTenant]
    /\ UNCHANGED << roleBindings, accessAttempts, clusterRoles >>

(*** ClusterRoles are cluster-wide, the admin creates them ***)
CreateClusterRole(actor, k, p) ==
    /\ actor \in ClusterAdmins
    /\ clusterRoles[k] = {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, accessAttempts >>

(*** ClusterRoles may be modified: Admins may add permissions to them ***)
UpdateClusterRole(actor, k, p) ==
    /\ actor \in ClusterAdmins
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = @ \cup {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, accessAttempts >>

(*** ClusterRole deletion implies removing the value of the mapping ***)
DeleteClusterRole(actor, k, p) ==
    /\ actor \in ClusterAdmins
    /\ clusterRoles[k] # {}
    /\ clusterRoles' = [clusterRoles EXCEPT ![k] = @ \ {p}]
    /\ UNCHANGED << nsTenantMap, roleBindings, accessAttempts >>

(*** Access is modified by creating/revoking a roleBinding ***)
GrantAccess(actor, ns, rbName, g, k) ==
    /\ actor \in ClusterAdmins
    /\ clusterRoles[k] # {}
    /\ roleBindings' = IF <<ns,rbName>> \in DOMAIN roleBindings THEN
                            [roleBindings EXCEPT ![<<ns, rbName>>] = 
                                IF @ # {}
                                THEN << @[1] \cup {g}, @[2] >>
                                ELSE << {g}, k >>]
                        ELSE <<ns, rbName>> :> <<{g}, k>> @@ roleBindings
    /\ UNCHANGED << nsTenantMap, accessAttempts, clusterRoles >>

RevokeAccess(actor, ns, rbName, g, k) ==
    /\ actor \in ClusterAdmins
    /\ nsTenantMap[ns] # NoTenant
    /\ <<ns, rbName>> \in DOMAIN roleBindings
    /\ roleBindings[<<ns, rbName>>] # {}
    /\ roleBindings' = [roleBindings EXCEPT ![<<ns, rbName>>] = 
                            IF Cardinality(@[1]) = 1 THEN 
                                {}
                            ELSE 
                            << @[1] \ {g}, @[2] >>]
    /\ UNCHANGED << nsTenantMap, accessAttempts, clusterRoles >>

(*** Track all accessAttempts ***)
AttemptedAccess(ns, g, p) ==
  /\ accessAttempts' = IF <<ns, g, p>> \in DOMAIN accessAttempts THEN
                            [accessAttempts EXCEPT ![<<ns, g, p>>] = MatchRoleBinding(ns, g, p)]
                       ELSE <<ns, g, p>>  :> MatchRoleBinding(ns, g, p) @@ accessAttempts
  /\ UNCHANGED << nsTenantMap, roleBindings, clusterRoles >>

Inv == 
  /\ TypeOK
  /\ BindingsRespectMT
  /\ NoCrossTenantSuccess

Next ==
  \E a \in ClusterAdmins, rbName \in RBNames, g \in (Groups \ ClusterAdmins), ns \in Namespaces, t \in Tenants,
  p \in Permissions, k \in ClusterRoleNames:
    \/ CreateNamespace(a, ns, t)
    \/ DeleteNamespace(a, ns, t)
    \/ CreateClusterRole(a, k, p)
    \/ UpdateClusterRole(a, k, p)
    \/ DeleteClusterRole(a, k, p)
    \/ GrantAccess(a, ns, rbName, g, k)
    \/ RevokeAccess(a, ns, rbName, g, k)
    \/ AttemptedAccess(ns, g, p)

Safety == Init /\ [][Next]_vars

=============================================================================
