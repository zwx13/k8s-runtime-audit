---- MODULE Utils ----
EXTENDS TLC, Json, Sequences, FiniteSets, Naturals, SequencesExt

SeqToSet(t) == { t[i] : i \in 1..Len(t) }

FunToSeq(f) == SetToSeq({<< k, f[k] >> : k \in DOMAIN f })
\* protect against dupes
SeqToFun(t) == 
  LET T == { t[i] : i \in 1..Len(t) }
      Keys == { pair[1] : pair \in T }
      valuesFor(k) == { pair[2] : pair \in { p \in T : p[1] = k } }
   IN 
    \*  /\ \A p, q \in T : p[1] = q[1] => p[2] = q[2] 
    [ key \in Keys |-> CHOOSE value \in valuesFor(key) : TRUE ]

Codomain(S) == UNION { S[x] : x \in DOMAIN S }

====