------------------------------ MODULE NatsOps ------------------------------
EXTENDS Naturals, Sequences

(* 
  Stub for TLC parsing; the actual implementation is in Java.
  NatsConsume(SUBJECT, DURABLE) 
  Java implementation consumes messages from NATS JetStream.
  Returns a tuple of records representing log messages.
*)
NatsConsume(SUBJECT, DURABLE) == TRUE

=============================================================================
\* Modification History
\* Last modified Tue Sep 23 09:50:58 EEST 2025 by malina
\* Created Tue Sep 23 09:50:08 EEST 2025 by malina
