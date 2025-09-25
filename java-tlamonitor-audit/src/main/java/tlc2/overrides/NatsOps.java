package tlc2.overrides;

import tlc2.NatsManager;
import tlc2.Utils;
import tlc2.overrides.TLAPlusOperator;
import tlc2.value.IValue;
import tlc2.value.impl.*;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;

import io.nats.client.*;

// TLA+ operator that fetches a single log message from NATS JetStream,
// converts it to an IValue (e.g., TupleValue, RecordValue),
// and can be called inside a TLA+ specification to iterate through logs in order.

 public class NatsOps {
    @TLAPlusOperator(identifier = "NatsConsume", module = "NatsOps")
    public static synchronized IValue consume(StringValue SUBJECT, StringValue DURABLE) throws IOException, JetStreamApiException, InterruptedException, JetStreamStatusCheckedException{
        try {
            List<IValue> messages = new ArrayList<>();
            ConsumerContext durableContext = NatsManager.getDurableConsumer(DURABLE.toString(), SUBJECT.toString());
            FetchConsumer fetchConsumer = durableContext.fetchMessages(50);
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
