package tlc2;

import java.io.IOError;
import java.io.IOException;

import io.nats.client.*;
import io.nats.client.api.ConsumerConfiguration;


public class NatsManager {
    private static Connection nc;
    private static JetStream js;
    private static StreamContext streamContext;

    // connection to NATS, jetStream instance and stream context are
    // initialized once per JVM run, before any static methods or
    // fields of the class are accessed
    static {
        try {
            String natsURL = System.getenv("NATS_URL");
            if (natsURL == null) {
                natsURL = "nats://127.0.0.1:4222";
            }
            nc = Nats.connect(natsURL);
            js = nc.jetStream();
            streamContext = js.getStreamContext("AUDIT");
        } catch (Exception e) {
            e.printStackTrace();
            throw new RuntimeException("Failed to connect to NATS", e);
        }
    }

    public static JetStream getJetStream() {
        return js;
    }

    public static StreamContext getStreamContext() {
        return streamContext;
    }

    public static ConsumerContext getDurableConsumer(String durableName, String subject) throws IOException, JetStreamApiException {
        ConsumerConfiguration cfg = ConsumerConfiguration.builder()
            .durable(durableName)
            .filterSubject(subject)
            .build();
        return streamContext.createOrUpdateConsumer(cfg);
    }

}
