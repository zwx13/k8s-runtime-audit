------------------------ MODULE NodeIsolationSystem ------------------------
EXTENDS Naturals, Sequences

CONSTANTS Tenants, Nodes

VARIABLES alloc

vars == <<alloc>>

TypeOK ==
  alloc \in [Nodes -> Tenants \cup {""}]

Init ==
  alloc = [n \in Nodes |-> ""]

Next ==
  \E ns \in Tenants :
    \E node \in Nodes :
      \/ alloc[node] = "" /\ alloc' = [alloc EXCEPT ![node] = ns]
      \/ alloc[node] = ns /\ UNCHANGED alloc

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Check that if a node is assigned to a tenant then every other tenant    *)
(* that it could be assigned to must be the same as initial one            *)
(***************************************************************************)
NodeIsolationInvariant ==
  \A n \in Nodes :
    \A t \in Tenants:
        alloc[n] = t => \A t2 \in Tenants : alloc[n] = t2 => t = t2
        
THEOREM Spec => []NodeIsolationInvariant
===============================================================================
