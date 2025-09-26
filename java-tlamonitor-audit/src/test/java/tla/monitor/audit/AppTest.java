package tla.monitor.audit;

import org.junit.Test;
import io.nats.client.*;

public class AppTest {

    @Test
    public void consumeNatsMessages() {
        try {
            String subject = "audit.node.per.tenant";

            ConsumerContext ephemeralContext = tlc2.NatsManager.getEphemeralConsumer(subject);
            FetchConsumer fetchConsumer = ephemeralContext.fetchMessages(50);

            int count = 0;
            Message msg;
            while ((msg = fetchConsumer.nextMessage()) != null) {
                System.out.println("Received message: " + msg.getSubject() + " size=" + msg.getData().length);
                msg.ack();
                count++;
            }

            assert count > 0 : "No messages received from NATS";

        } catch (Exception e) {
            e.printStackTrace();
            assert false : "Failed to fetch NATS messages";
        }
    }
}
