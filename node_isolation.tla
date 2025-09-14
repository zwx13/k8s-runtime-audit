------------------------------ MODULE node_isolation ------------------------------
EXTENDS TLC, Json, Sequences, FiniteSets, Naturals

CONSTANTS 
  Tenants,   \* e.g. {"tenant1", "tenant2"}
  LogFile,
  AllocFile,
  AlertFile

VARIABLES 
  idx,       
  alloc,
  allocInit
  
vars == <<idx, alloc>>

(***************************************************************************)
(* ndJsonDeserialize for NDJSON: one JSON object per line.                 *)
(***************************************************************************)
LogEvents == ndJsonDeserialize(LogFile)

\*PrintLogStart == PrintT("=== RAW LOG EVENTS ===")
\*PrintAllLogs  == PrintT(LogEvents)
\*PrintFirst    == PrintT(LogEvents[1])
\*PrintSecond   == PrintT(LogEvents[2])


(***************************************************************************)
(* We only care about "verb=create" for pods in {tenant1,tenant2}, with    *)
(* responseStatus=201, and there must be a node                            *)
(***************************************************************************)
IsRelevant(e) ==
  /\ e["verb"] = "create"
  /\ e["objectRef"]["resource"] = "pods"
  /\ e["objectRef"]["namespace"] \in Tenants
  /\ e["responseStatus"]["code"] = 201
  /\ e["requestObject"]["spec"]["nodeSelector"]["kubernetes.io/hostname"] /= ""

(***************************************************************************)
(* Access to individual node and ns and pods                               *)
(***************************************************************************)
GetNamespace(e) == e["objectRef"]["namespace"]
GetNode(e)      == e["requestObject"]["spec"]["nodeSelector"]["kubernetes.io/hostname"]
GetPod(e)       == e["objectRef"]["name"]

(***************************************************************************)
(* Collect nodes, pods from relevant events so we can initialize our map   *)
(* GetAllNodes is a set since we want unique names and we just care about  *)
(* which exist, we do not want dupes                                       *)
(* GetAllPods is a sequence since we want to process pods as they appear   *)
(*   And pods can die and then be rescheduled again                        *)
(***************************************************************************)
GetAllNodes(events) ==
    { GetNode(events[i]) : i \in 1..Len(events) }
    
GetAllPods(events) ==
  [i \in 1..Len(events) |-> 
    [namespace |-> GetNamespace(events[i]),
     node      |-> GetNode(events[i])]]

(***************************************************************************)
(* In the initial state, idx = 1, and either no node is "allocated" to any *)
(* tenant, or we continue with previous allocation from batches            *)
(***************************************************************************)
Init ==
  /\ idx = 1
  /\ allocInit = IF AllocFile = "NONE"
              THEN [n \in GetAllNodes(LogEvents) |-> ""]
              ELSE JsonDeserialize(AllocFile)
  /\ alloc = [n \in GetAllNodes(LogEvents) |-> IF n \in DOMAIN allocInit 
              THEN allocInit[n] 
              ELSE ""]

\*  /\ PrintLogStart
\*  /\ PrintAllLogs
\*  /\ PrintFirst
\*  /\ PrintSecond


(***************************************************************************)
(* At each step, we move forward in the sequence of LogEvents.  If the new *)
(* event is "relevant," we assign the node or check for conflicts.         *)
(***************************************************************************)
Next ==
  /\ idx <= Len(LogEvents)
  /\ LET ev == LogEvents[idx]
     IN /\ IF IsRelevant(ev) THEN
              IF alloc[GetNode(ev)] = "" THEN
                  alloc' = [alloc EXCEPT ![GetNode(ev)] = GetNamespace(ev)]
              ELSE IF alloc[GetNode(ev)] = GetNamespace(ev) THEN
                      UNCHANGED alloc
              ELSE UNCHANGED alloc
           ELSE UNCHANGED alloc
        /\ idx' = idx + 1
        /\ UNCHANGED allocInit
        
        
\*Alert ==
\*    LET ev == LogEvents[idx]
\*    IN JsonSerialize(AlertFile, 
\*         [namespace |-> GetNamespace(ev),
\*          node |-> GetNode(ev),
\*          message |-> "Invariant violated!",
\*          index |-> idx])
\* 

(***************************************************************************)
(* Invariant: each node can belong only to one tenant.                     *)
(* If this event tries to schedule a new tenant on an already-claimed node,*)
(* it will violate the property                                            *)
(***************************************************************************)
Invariant ==
  idx <= Len(LogEvents)
  => LET ev == LogEvents[idx] IN
       IF /\ IsRelevant(ev)
          /\ ~(alloc[GetNode(ev)] = "" \/ alloc[GetNode(ev)] = GetNamespace(ev))
       THEN
         /\ PrintT("ALERT: Invariant violated in batch file: " \o ToString(LogFile))
         /\ PrintT("Namespace: " \o ToString(GetNamespace(ev)))
         /\ PrintT("Node: " \o ToString(GetNode(ev)))
\*         /\ Alert
         /\ FALSE
       ELSE
         TRUE
         
SerializeAtEnd ==
  /\ idx > Len(LogEvents)
  /\ JsonSerialize(AllocFile, alloc)
  /\ UNCHANGED <<allocInit, alloc, idx>>
 
NextButSerialize == Next \/ SerializeAtEnd
         
Spec == Init /\ [][NextButSerialize]_vars
         
(***************************************************************************)
(* These are the substitutions we do in the inner-most module that has the *)
(* System level spec;; behavior of alloc here in the real trace should     *)
(* match alloc in the system specification                                 *)
(***************************************************************************)
System == INSTANCE NodeIsolationSystem 
            WITH Nodes <- GetAllNodes(LogEvents), 
                 alloc <- alloc,
                 Tenants <- Tenants
            

THEOREM Spec => System!Spec
===============================================================================
