---- MODULE Utils ----
EXTENDS TLC, Json, Sequences, FiniteSets, Naturals, SequencesExt

SeqToSet(t) == { t[i] : i \in 1..Len(t) }

FunToSeq(f) == SetToSeq({<< k, f[k] >> : k \in DOMAIN f })

\* << <<a, b>>, <<d, c>> >> to
\* [a |-> b, d |-> c]
\* turn all pairs to a single set
\* take keys and values and make a function
\* avoid dupes?
SeqToFun(t) ==
    LET 
        setOfPairs == SeqToSet(t)
        keys == {tuple[1] : tuple \in setOfPairs}
        valuesForKey(key) == {tuple[2] : tuple \in { pair \in setOfPairs : pair[1] = key} }
    IN
        [key \in keys |-> CHOOSE value \in valuesForKey(key): TRUE]


Codomain(S) == UNION { S[x] : x \in DOMAIN S }

====