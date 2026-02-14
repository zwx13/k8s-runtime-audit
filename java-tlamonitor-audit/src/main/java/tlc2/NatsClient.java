package tlc2;

import java.io.IOException;
import java.util.concurrent.atomic.AtomicBoolean;

import io.nats.client.*;
import io.nats.client.api.*;


public class NatsClient {
    private static final Connection nc;
    private static final JetStream js;
    private static final StreamContext streamContext;

    private static final String NATS_URL;
    private static final String STREAM;

    private static final AtomicBoolean CLOSED = new AtomicBoolean(false);

    // connection to NATS, jetStream instance and stream context are
    // initialized once per JVM run, before any static methods or
    // fields of the class are accessed
    static {
        try {
            NATS_URL = Utils.env("NATS_URL", "nats://127.0.0.1:4222");
            STREAM = Utils.env("JS_STREAM", "AUDIT_MT");

            Options opts = new Options.Builder()
                    .server(NATS_URL)
                    .build();

            nc = Nats.connect(opts);
            js = nc.jetStream();
            streamContext = js.getStreamContext(STREAM);

            Runtime.getRuntime().addShutdownHook(new Thread(NatsClient::close, "nats-shutdown"));
        } catch (Exception e) {
            e.printStackTrace();
            throw new RuntimeException("Failed to connect to NATS/Jetstream", e);
        }
    }

    private NatsClient() {}

    public static JetStream getJetStream() { return js; }

    public static StreamContext getStreamContext() { return streamContext; }

    public static ConsumerContext getDurableConsumer(String durableName, String subject) throws Exception {
        ConsumerConfiguration cfg = ConsumerConfiguration.builder()
            .durable(durableName)
            .filterSubject(subject)
            .ackPolicy(AckPolicy.Explicit)
            .build();
        return streamContext.createOrUpdateConsumer(cfg);
    }

    public static ConsumerContext getEphemeralConsumer(String subject) throws Exception {
        ConsumerConfiguration cfg = ConsumerConfiguration.builder()
            .filterSubject(subject)
            .build();
        return streamContext.createOrUpdateConsumer(cfg);
    }
    
    public static void close() {
        if (!CLOSED.compareAndSet(false, true)) return;

        try {
            nc.drain(java.time.Duration.ofSeconds(2));
        }
        catch (Exception ignored) {
        }
        finally {
            try { nc.close(); } catch (Exception ignored) {}
        }
    }

    public static KeyValue getKVManagement(String kvName) throws Exception{
        KeyValueManagement kvm = nc.keyValueManagement();
        KeyValueConfiguration kvc = KeyValueConfiguration.builder()
            .name(kvName)
            .build();
        KeyValueStatus keyValueStatus = kvm.create(kvc);
        KeyValue kv = nc.keyValue(kvName);
        return kv;
    }

}
