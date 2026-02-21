------------------------------ MODULE NatsOps ------------------------------
EXTENDS Naturals, Sequences
LOCAL INSTANCE TLC
LOCAL INSTANCE Integers

(* 
  Stub for TLC parsing; the actual implementation is in Java.
  NatsConsume() 
  Java implementation consumes messages from NATS JetStream.
  Returns a tuple of records representing log messages.
*)
NatsConsume == TRUE

NatsAckBatch == TRUE

NatsLoadCachedState == TRUE

NatsPutCachedState(allocOut) == TRUE

NatsPublishAlert(log, allocOut) == TRUE

=============================================================================
\* Modification History
\* Last modified Tue Sep 23 09:50:58 EEST 2025 by malina
\* Created Tue Sep 23 09:50:08 EEST 2025 by malina
