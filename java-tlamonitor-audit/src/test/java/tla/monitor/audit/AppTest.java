package tla.monitor.audit;

import org.junit.Test;
import org.junit.Ignore;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.List;
import java.util.ArrayList;

import io.nats.client.*;
import tlc2.Utils;
import tlc2.value.IValue;
import tlc2.value.impl.TupleValue;
import tlc2.value.impl.Value;

// @Ignore("Disabled during packaging")

public class AppTest {
    private static final String subject = "audit.multitenancy";
    private static final String durable = "junit-durable-test";
    @Test
    public void ephConsumerTest() throws Exception {
            List<IValue> messages = new ArrayList<>();
            ConsumerContext ephemeralContext = tlc2.NatsClient.getEphemeralConsumer(subject);
            FetchConsumer fetchConsumer = ephemeralContext.fetchMessages(50);
            Message msg;

            while ((msg = fetchConsumer.nextMessage()) != null) {
                byte[] msgData = msg.getData();
                System.out.println("Msgdata size=" + msgData.length);
                JsonNode jsonMessage = Utils.parseAndGetJson(msgData);
                System.out.println("Json message: " + jsonMessage.toString());
                System.out.println("Json type: " + jsonMessage.getNodeType());
                IValue tlaValue = Utils.getValueFromJson(jsonMessage);
                System.out.println("TLA+ value: " + tlaValue.toString());
                String tlaType = jsonMessage.path("tlaType").asText(null);
                System.out.println("tlaType= " + tlaType);
                msg.ack();
                messages.add(tlaValue);
            }
            // TupleValue result = new TupleValue(messages.toArray(new Value[0]));
            // System.out.println("Result: " + result.toString());
    }

    @Test
    public void durConsumerTest() throws Exception {
        ConsumerContext durableCtx = tlc2.NatsClient.getDurableConsumer(durable, subject);

        FetchConsumer fc = durableCtx.fetchMessages(10);
        Message msg;
        int acked = 0;

        while ((msg = fc.nextMessage()) != null) {
            JsonNode json = Utils.parseAndGetJson(msg.getData());
            String tlaType = json.path("tlaType").asText(null);
            System.out.println("tlaType= " + tlaType);

            msg.ack();
            acked++;
        }

        System.out.println("Acked " + acked);

        FetchConsumer fc2 = durableCtx.fetchMessages(10);
        Message msg2 = fc2.nextMessage();

        if (msg2 != null) {
            throw new AssertionError("Expected no new messages but got one, why?");
        }
    }
}