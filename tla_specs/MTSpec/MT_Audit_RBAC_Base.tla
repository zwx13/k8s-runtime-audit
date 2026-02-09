---- MODULE MT_Audit_RBAC_Base ----
EXTENDS Naturals, FiniteSets

(***************************************************************************)
(*                                                                         *)
(*  Multitenancy (MT) Ground Truth Specification                            *)
(*                                                                         *)
(*  The core idea of this spec is that namespace labels are treated as    *)
(*  the absolute source of truth for multitenancy.                        *)
(*                                                                         *)
(*  RoleBindings must always be consistent with this truth:                *)
(*    - users may only be bound to namespaces that belong to their tenant   *)
(*    - no cross-tenant bindings are allowed                                *)
(*                                                                         *)
(*  This module defines the ideal, correct behavior of the system.        *)
(*  It assumes no mistakes and encodes the intended MT discipline.          *)
(*                                                                         *)
(*  A separate trace specification replays real Kubernetes audit logs       *)
(*  and checks whether the observed behavior violates any of the            *)
(*  invariants defined here.                                                *)
(*                                                                         *)
(*  Note: users themselves are created outside of Kubernetes (e.g., via     *)
(*  client certificates). Therefore, the mapping from users to tenants is   *)
(*  provided as an external constant and treated as absolute truth.         *)
(*                                                                         *)
(* To do:                                                                   *)
(* - add cluster roles, cluster role bindings                               *)
(* - instead of <<v, r>> use p then unpack if necessary                     *)
(* - decide if we keep NoRole or {                                          *)
(* - decide on NoDanglingBinding invariant, or def in GrantAccess           *)
(* - add NetworkPolicy, resourceQuotas, TT, AntiAffinity?                                                   *)
(***************************************************************************)


\* constants are k8s resources and the UserTenantMap that we use as absolute truth
CONSTANTS Users, Tenants, NoTenant, Namespaces, RoleNames,
 Admins, Verbs, Resources, UserTenantMap, Codes, SuccessCodes, FailCodes
\* assume statements are for constants, 
\* typeOK is for variables
\* admins are users but they belong to no tenant
ASSUME Admins \subseteq Users
ASSUME \A a \in Admins : UserTenantMap[a] = NoTenant

ASSUME UserTenantMap \in [Users -> (Tenants \cup {NoTenant})]

ASSUME SuccessCodes \subseteq Codes
ASSUME FailCodes \subseteq Codes
ASSUME SuccessCodes \cap FailCodes = {}
ASSUME SuccessCodes \cup FailCodes = Codes

VARIABLES nsTenant, roleBindings, accessAttempts, roleRules

vars == << nsTenant, roleBindings, accessAttempts, roleRules >>

\* this creates a set of tuples (permissions)
\* because order matters and we group
Permission == Verbs \X Resources

SameTenant(u, ns) ==
  /\ nsTenant[ns] # NoTenant
  /\ UserTenantMap[u] = nsTenant[ns]

MatchRole(u, ns, v, r) ==
  \E rn \in RoleNames :
      /\ << u, ns, rn >> \in roleBindings
      /\ <<v, r>> \in roleRules[<<ns, rn>>]

ShouldAllow(u, ns, v, r) ==
    /\ SameTenant(u, ns)
    /\ MatchRole(u, ns, v, r)

\* RBs consistent with tenant truth
\* we want role bindings to always abide by the absolute truth
\* that we define as a constant
BindingsRespectMT ==
    \A u \in Users, ns \in Namespaces, rn \in RoleNames :
      << u, ns, rn >> \in roleBindings => SameTenant(u, ns)

\* Access results consistent with RBs
\* Should allow:
\* - namespace belongs to tenant that user belongs to (absolute truth)
\* - a corresponding role exists and is bounded
NoCrossTenantSuccess ==
    \A u \in Users, ns \in Namespaces, 
       v \in Verbs, r \in Resources, code \in Codes :
      (<<u, ns, v, r, code>> \in accessAttempts /\ code \in SuccessCodes)
        => SameTenant(u, ns)

\* debug
UserInRBExists ==
    \A <<u, ns, rn>> \in roleBindings : u \in Users

\* if a RB refers to a role key, that role must be defined
\* so far this forbids empty roles, which is fine (for now?)
\* NoDanglingBindings ==
\*   \A u \in Users, ns \in Namespaces, rn \in RoleNames :
\*     (<<u, ns, rn>> \in roleBindings) =>
\*       roleRules[<<ns, rn>>] # {}

TypeOK ==
  /\ nsTenant \in [Namespaces -> (Tenants \cup {NoTenant})]
  \* we cannot model roleBindings as a function because
  \* for the same input we might get multiple outputs
  /\  roleBindings \in SUBSET (Users \X Namespaces \X RoleNames)
  \* roles are namespaced and define a set of rules
  /\ roleRules \in [Namespaces \X RoleNames -> SUBSET Permission]
  /\ accessAttempts \in SUBSET (Users \X Namespaces \X Verbs \X Resources \X Codes)
    
Init == 
  /\ nsTenant = [ns \in Namespaces |-> NoTenant]
  /\ roleBindings = {}
  /\ accessAttempts = {}
  /\ roleRules = [k \in (Namespaces \X RoleNames) |-> {} ]

\* we allow creation ofnsnamespace, no further modification
CreateNamespace(admin, ns, t) ==
    /\ nsTenant[ns] = NoTenant
    /\ nsTenant' = [nsTenant EXCEPT ![ns] = t]
    /\ UNCHANGED << roleBindings, accessAttempts, roleRules >>

CreateRole(admin, rn, ns, v, r) ==
    /\ nsTenant[ns] # NoTenant
    /\ roleRules' = [roleRules EXCEPT ![<<ns, rn>>] = @ \cup { <<v, r>> }]
    /\ UNCHANGED << nsTenant, roleBindings, accessAttempts >>

\* admin grants/revokes access primarily by creating/deleting RoleBindings 
\* (or ClusterRoleBindings); 
\* roles/ClusterRoles define the permission sets and 
\* are similar to templates

GrantAccess(admin, u, ns, rn) ==
    /\ nsTenant[ns] # NoTenant
    /\ UserTenantMap[u] = nsTenant[ns]
    /\ roleRules[<<ns, rn>>] # {}     \* 2keep, delete?
    /\ roleBindings' = roleBindings \cup {<<u, ns, rn>>}
    /\ UNCHANGED << nsTenant, accessAttempts, roleRules >>

RevokeAccess(admin, u, ns, rn) ==
    /\ nsTenant[ns] # NoTenant
    /\ roleBindings' = roleBindings \ {<<u, ns, rn>>}
    /\ UNCHANGED << nsTenant, accessAttempts, roleRules >>

\* Any authenticated user may attempt access to any namespace.
\* Authorization is evaluated after the request is made.
\* Access may be denied for legitimate reasons:
\*  - the namespace does not belong to the user's tenant (violates absolute tenant truth)
\*  - no role exists defining the requested permission
\*  - no role binding exists attaching that role to the user
\* Only the first case represents a multi-tenancy safety violation.
\* The others are expected authorization failures.
AttemptedAccess(u, ns, v, r, code) ==
  /\ IF ShouldAllow(u, ns, v, r) THEN code \in SuccessCodes ELSE code \in FailCodes
  /\ accessAttempts' = accessAttempts \cup {<<u, ns, v, r, code>>}
  /\ UNCHANGED << nsTenant, roleBindings, roleRules >>

Inv == 
\*   /\ UserInRBExists
  /\ TypeOK
  /\ BindingsRespectMT
  /\ NoCrossTenantSuccess
\*   /\ NoDanglingBindings

Next ==
  \E admin \in Admins, u \in Users, ns \in Namespaces, t \in Tenants,
  v \in Verbs, r \in Resources, rn \in RoleNames, code \in Codes :
    \/ CreateNamespace(admin, ns, t)
    \/ CreateRole(admin, rn, ns, v, r)
    \/ GrantAccess(admin, u, ns, rn)
    \/ RevokeAccess(admin, u, ns, rn)
    \/ AttemptedAccess(u, ns, v, r, code)

Safety == Init /\ [][Next]_vars

=============================================================================
