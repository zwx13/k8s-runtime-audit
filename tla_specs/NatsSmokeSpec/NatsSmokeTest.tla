---- MODULE NatsSmokeTest ----
EXTENDS Naturals, NatsOps, TLC

VARIABLES logs, done

vars == << logs, done >>

Init == 
    /\ done = FALSE
    /\ logs = NatsConsume
    /\ PrintT("=== NATS SMOKE TEST ===")
    \* /\ PrintT("logs (raw) = " \o ToString(logs))
    /\ PrintT("Len(logs)  = " \o ToString(Len(logs)))
    /\ IF Len(logs) >= 1
            THEN PrintT("logs[1] = " \o ToString(logs[1]))
            ELSE PrintT("logs is empty")
    
Next ==
    /\ ~done
    /\ PrintT("Calling natsAckBatch")
    /\ NatsAckBatch
    /\ done' = TRUE
    /\ UNCHANGED <<logs>>
    
Spec == Init /\ [][Next]_vars
    
Termination == done = FALSE


=====