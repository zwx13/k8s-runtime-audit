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

@Ignore("Disabled during packaging")

public class AppTest {

    @Test
    public void consumeNatsMessages() {
        try {
            String subject = "audit.node.per.tenant";
            List<IValue> messages = new ArrayList<>();
            ConsumerContext ephemeralContext = tlc2.NatsManager.getEphemeralConsumer(subject);
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
                msg.ack();
                messages.add(tlaValue);
            }
            TupleValue result = new TupleValue(messages.toArray(new Value[0]));
            System.out.println("Result: " + result.toString());
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}