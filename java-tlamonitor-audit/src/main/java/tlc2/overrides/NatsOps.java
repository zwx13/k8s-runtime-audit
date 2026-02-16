package tlc2.overrides;

import tlc2.NatsClient;
import tlc2.Utils;
import tlc2.value.IValue;
import tlc2.value.impl.*;
import util.UniqueString;

import java.util.ArrayList;
import java.util.List;
import java.util.NavigableMap;
import java.util.TreeMap;

import javax.management.RuntimeErrorException;

import java.time.Instant;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import io.nats.client.*;
import io.nats.client.api.*;

// 2do: update operator or create a new one, that operates on continuous logs
// check to see how kafka onos peeps did it
// go lower level? kafka peeps: https://github.com/onosproject/tlaplus-monitor/blob/master/src/main/java/tlc2/overrides/Traces.java

// !!!! the consume operator takes as long as we configure ack_wait to be

// TLA+ operator that fetches 50 messages from NATS JetStream,
// converts them to an IValue (e.g., TupleValue, RecordValue),
// adds them to messages List; at the end, turn this list to a Tuple.
// can be called inside a TLA+ specification to iterate through logs in order.
 public class NatsOps {

    private static String DURABLE = Utils.env("TLA_DURABLE", "audit-mt-tla-filter");
    private static String SUBJECT = Utils.env("TLA_SUBJECT", "audit.multitenancy");
    private static int MESSAGES_NO = Utils.envInt("TLA_MESSAGES_NO", 50);

    private static String KV_NAME = Utils.env("TLA_KV_NAME", "audit-mt-tla-state");

    private static boolean fetchedMsgOnce = false;
    private static boolean ackedOnce = false;
    private static boolean fetchedStateOnce = false;
    private static boolean putStateOnce = false;
    private static boolean publishedAlert = false;

    private static NavigableMap<Long, Message> currentMessages = new TreeMap<>();
    private static List<IValue> cachedTlaValues = new ArrayList<>();

    private static KeyValue kv;
    private static KeyValueEntry kvEntry;
    private static IValue cachedTlaState;

    @TLAPlusOperator(identifier = "NatsConsume", module = "NatsOps")
    public static synchronized Value consume() throws Exception {
        long t0 = System.nanoTime();
        System.err.println(">>>>>> NatsConsume start " + Instant.now());
        if (fetchedMsgOnce) {
            return new TupleValue(cachedTlaValues.toArray(new Value[0]));
        }
        try {
            FetchConsumeOptions opts = FetchConsumeOptions.builder()
                .maxMessages(MESSAGES_NO)
                .expiresIn(1000)
                .build();
            ConsumerContext durableContext = NatsClient.getDurableConsumer(DURABLE, SUBJECT);
            FetchConsumer fetchConsumer = durableContext.fetch(opts);

            Message msg;
            while ((msg = fetchConsumer.nextMessage()) != null) {
                currentMessages.put(msg.metaData().streamSequence(), msg);
            }

            for (Message m : currentMessages.values()) {
                byte[] msgData = m.getData();
                JsonNode jsonMessage = Utils.parseAndGetJson(msgData);
                IValue tlaValue = Utils.getValueFromJson(jsonMessage);
                cachedTlaValues.add(tlaValue);
            }
                fetchedMsgOnce = true;
                return new TupleValue(cachedTlaValues.toArray(new Value[0]));
        }
         catch (Exception e) {
            e.printStackTrace();
            // reset partial state so that next call can try again cleanly
            fetchedMsgOnce = false;
            currentMessages.clear();
            cachedTlaValues.clear();
            // return new StringValue("ERROR");
            throw new RuntimeException("NatsConsume failed", e);
        }
        finally {
            System.err.println(">>>>>> NatsConsume end " + Instant.now()
                        + " elapsedMs=" + (System.nanoTime() - t0)/1_000_000);
        }
    }
 
    // we need to set MaxAckPending to max or 50
    // and ack_wait to max or more
    @TLAPlusOperator(identifier = "NatsAckBatch", module = "NatsOps")
    public static synchronized Value ackBatch() throws Exception {
        long t0 = System.nanoTime();
        System.err.println(">>>>>> NatsAckBatch start " + Instant.now());
        // idempotence
        if (ackedOnce) {
            return BoolValue.ValTrue;
        }

        try {
            if (currentMessages.isEmpty()) {
                ackedOnce = true;
                return BoolValue.ValTrue;
            }
                for (Message msg : currentMessages.values()) {
                    msg.ack();
                }

                System.out.println("We acked seq " + currentMessages.firstKey() + " to " + currentMessages.lastKey());
                ackedOnce = true;
                return BoolValue.ValTrue;
            } 
        
        catch (Exception e) {
            e.printStackTrace();
            // we do not set ackedOnce=true on failure
            // so next call can try acks
            throw e;
            // return BoolValue.ValFalse;
        }
        
        finally {
            System.err.println(">>>>>> NatsAckBatch end " + Instant.now()
                        + " elapsedMs=" + (System.nanoTime() - t0)/1_000_000);
        }
    }

    @TLAPlusOperator(identifier = "NatsLoadCachedState", module = "NatsOps")
    public static synchronized Value loadCachedState() throws Exception {
        if (fetchedStateOnce) {
            return (Value) cachedTlaState;  
        }
        
        try {
            kv = NatsClient.getKVManagement(KV_NAME);
            kvEntry = kv.get("cachedState");

            if (kvEntry == null || kvEntry.getValue() == null || kvEntry.getValue().length == 0) {
                cachedTlaState = RecordValue.EmptyRcd;
            } else {
                byte[] value = kvEntry.getValue();
                JsonNode jsonValue = Utils.parseAndGetJson(value);
                cachedTlaState = (Value) Utils.getValueFromJson(jsonValue);
            }
        } catch (Exception e) {
            throw new RuntimeException("Failed to load KV cachedState from bucket " + KV_NAME, e);
        }

        fetchedStateOnce = true;
        
        return (Value) cachedTlaState;
        
    }

    @TLAPlusOperator(identifier = "NatsPutCachedState", module = "NatsOps")
    public static synchronized Value putCachedState(RecordValue allocOut) throws Exception {
        JsonNode allocJson;
        if (putStateOnce) {
            return BoolValue.ValTrue;
        }
        
        try {
            allocJson = Utils.getJsonFromValue(allocOut);
            kv = NatsClient.getKVManagement(KV_NAME);
            kv.put("cachedState", new ObjectMapper().writeValueAsBytes(allocJson));
            System.out.println("We saved the final state in KV");

        } catch (Exception e) {
            e.printStackTrace();
            throw new RuntimeException("Failed to put KV pair cachedState in bucket " + KV_NAME, e);
        }

        putStateOnce = true;
        
        return BoolValue.ValTrue;
        
    }

    // @TLAPlusOperator(identifier = "NatsPublishAlert", module = "NatsOps")
    // public static synchronized Value publishAlert() throws Exception {
    //     if (publishedAlert) {
    //         return;
    //     }
    //     try {
            
    //     }
    // }
    
}
