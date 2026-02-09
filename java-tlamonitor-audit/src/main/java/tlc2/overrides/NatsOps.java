package tlc2.overrides;

import tlc2.NatsClient;
import tlc2.Utils;
import tlc2.value.IValue;
import tlc2.value.impl.*;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

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
    @TLAPlusOperator(identifier = "NatsConsume", module = "NatsOps")
    public static synchronized IValue consume(StringValue SUBJECT, StringValue DURABLE, IntValue MESSAGES_NO) throws IOException, JetStreamApiException, InterruptedException, JetStreamStatusCheckedException{
        try {
            List<IValue> messages = new ArrayList<>();
            ConsumerContext durableContext = NatsClient.getDurableConsumer(DURABLE.toUnquotedString(), SUBJECT.toUnquotedString());
            FetchConsumer fetchConsumer = durableContext.fetchMessages(MESSAGES_NO.val);
            Message msg;
            while ((msg = fetchConsumer.nextMessage()) != null)
            {
                byte[] msgData = msg.getData();
                JsonNode jsonMessage = Utils.parseAndGetJson(msgData);
                IValue tlaValue = Utils.getValueFromJson(jsonMessage);
                msg.ack();
                messages.add(tlaValue);
            }
            return new TupleValue(messages.toArray(new Value[0]));

        } catch (Exception e) {
            e.printStackTrace();
            return new StringValue("ERROR");
        }
    }
}
