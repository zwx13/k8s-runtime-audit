/**
 * This file handles the connection to NATS and JetStream.
 * It also contains functions that interact with consumers
 * and KV buckets.
 */

package tlc2;

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

     /**
     * 
     * Connection to NATS, JetStream instance, and stream context are
     * initialized once per JVM run, before any static methods or
     * fields of the class are accessed.
     */
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

    /**
     * Returns the shared JetStream client used to interact with NATS JetStream.
     *
     * The {@link JetStream} instance is the general API entry point for
     * publishing messages, accessing stream information, and working with
     * JetStream features.
     */
    public static JetStream getJetStream() { return js; }

    /**
     * Returns the context for the configured JetStream stream.
     *
     * The {@link StreamContext} represents operations scoped to a specific
     * stream, such as accessing consumers, orstream state.
     */
    public static StreamContext getStreamContext() { return streamContext; }

    /**
     * Gets a durable consumer or creates it if missing.
     * * @param durableName The name of the durable associated with a consumer.
     * @param subject       The subject of the stream we want to consume from.
     * @return              The consumer to match the given configuration.
     * @throws Exception    Depending on the cause of the error (mostly JetStreamAPIException)
     */
    public static ConsumerContext getDurableConsumer(String durableName, String subject) throws Exception {
        ConsumerConfiguration cfg = ConsumerConfiguration.builder()
            .durable(durableName)
            .filterSubject(subject)
            .ackPolicy(AckPolicy.Explicit)
            .build();
        return streamContext.createOrUpdateConsumer(cfg);
    }

    /**
     * Gets an ephemeral consumer or creates it if missing.
     * * @param subject       The subject of the stream we want to consume from.
     *   @return              The consumer to match the given configuration.
     *   @throws Exception    Depending on the cause of the error (mostly JetStreamAPIException)
     */
    public static ConsumerContext getEphemeralConsumer(String subject) throws Exception {
        ConsumerConfiguration cfg = ConsumerConfiguration.builder()
            .filterSubject(subject)
            .build();
        return streamContext.createOrUpdateConsumer(cfg);
    }
    
    /**
     * Closes the connection in a thread-safe way.
     * First call changes the state from {@code false} to {@code true}, next
     * calls just return.
     * 
     * Exceptions are ignored because the purpose is shutting down the connection.
     */
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

    /**
     * Gets a key-value pair from a KV bucket.
     */
    public static KeyValue getKV(String kvName) throws Exception {
        return nc.keyValue(kvName);
    }

}
