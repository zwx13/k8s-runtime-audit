zsazuuuupackage tlc2.overrides;

import tlc2.NatsClient;
import tlc2.Utils;
import tlc2.value.IValue;
import tlc2.value.impl.*;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.NavigableMap;
import java.util.TreeMap;
import java.util.HashMap;

import com.fasterxml.jackson.databind.JsonNode;

import io.nats.client.*;

// 2do: update operator or create a new one, that operates on continuous logs
// check to see how kafka onos peeps did it
// go lower level? kafka peeps: https://github.com/onosproject/tlaplus-monitor/blob/master/src/main/java/tlc2/overrides/Traces.java

// TLA+ operator that fetches 50 messages from NATS JetStream,
// converts them to an IValue (e.g., TupleValue, RecordValue),
// adds them to messages List; at the end, turn this list to a Tuple.
// can be called inside a TLA+ specification to iterate through logs in order.
 public class NatsOps {

    private static String DURABLE = Utils.env("TLA_DURABLE", "audit-mt-tla-filter");
    private static String SUBJECT = Utils.env("TLA_SUBJECT", "audit.multitenancy");
    private static int MESSAGES_NO = Utils.envInt("TLA_MESSAGES_NO", 50);

    private static boolean fetchedMsgOnce = false;
    private static boolean ackedOnce = false;

    private static NavigableMap<Long, Message> currentMessages = new TreeMap<>();
    private static List<IValue> cachedTlaValues = new ArrayList<>();

    @TLAPlusOperator(identifier = "NatsConsume", module = "NatsOps")
    public static synchronized IValue consume() throws Exception {
        if (fetchedMsgOnce) {
            return new TupleValue(cachedTlaValues.toArray(new Value[0]));
        }
        try {
            ConsumerContext durableContext = NatsClient.getDurableConsumer(DURABLE, SUBJECT);
            FetchConsumer fetchConsumer = durableContext.fetchMessages((MESSAGES_NO));

            Message msg;
            while ((msg = fetchConsumer.nextMessage()) != null) {
                currentMessages.put(msg.metaData().streamSequence(), msg);
            }

            for (Message m : currentMessages.values()) {
                byte[] msgData = msg.getData();
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
            return new StringValue("ERROR");
        }
    }
 
    // we need to set MaxAckPending to max or 50
    // and ack_wait to max or more
    @TLAPlusOperator(identifier = "NatsAckBatch", module = "NatsOps")
    public static synchronized void ackBatch() throws Exception {
        // idempotence
        if (ackedOnce) {
            return;
        }

        try {
            if (currentMessages.isEmpty()) {
                ackedOnce = true;
                return;
            }
                for (Message msg : currentMessages.values()) {
                    msg.ack();
                }

                System.out.println("We acked seq " + currentMessages.firstKey() + " to " + currentMessages.lastKey());
                ackedOnce = true;
            } catch (Exception e) {
            e.printStackTrace();
            // we do not set ackedOnce=true on failure
            // so next call can try acks
        }
    }
    
}
