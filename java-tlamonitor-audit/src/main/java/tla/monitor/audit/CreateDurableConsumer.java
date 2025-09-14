package tla.monitor.audit;

import java.io.IOException;

import io.nats.client.*;
import io.nats.client.api.ConsumerConfiguration;
import io.nats.client.ConsumerContext;
import io.nats.client.FetchConsumeOptions;
import io.nats.client.FetchConsumer;
import io.nats.client.JetStream;
import io.nats.client.JetStreamApiException;
import io.nats.client.Message;
import io.nats.client.Nats;
import io.nats.client.StreamContext;

import com.fasterxml.jackson.databind.JsonNode;

/* Purpose of this file is to consume from the audit.node.per.tenant subject (with durable)
 * and send the consumed logs to tlc. Logs should be persistent and when we stop the scripts,
 * and then turn back on again, the index should be preserved so we use
 * a durable consumer
 */

public class CreateDurableConsumer {
    public static void create() throws IOException, InterruptedException, JetStreamApiException {
        String natsURL = System.getenv("NATS_URL"); 
        if (natsURL == null) {
            natsURL = "nats://127.0.0.1:4222";
        }

        try (Connection nc = Nats.connect(natsURL)) {
            JetStream js = nc.jetStream();
            String DURABLE = "audit-nodeiso-tla";
            String SUBJECT = "audit.node.per.tenant";

            StreamContext streamContext = js.getStreamContext("AUDIT");
            ConsumerConfiguration durableConfig = ConsumerConfiguration.builder()
                    .durable(DURABLE)
                    .filterSubject(SUBJECT)
                    .build();
            ConsumerContext durableContext = streamContext.createOrUpdateConsumer(durableConfig);

            // use instead of hardcoded number
            // FetchConsumeOptions fetchConsumeOptions = FetchConsumeOptions.builder().noWait().build();

            
            // while (true) {
            //     try (FetchConsumer fetchConsumer = durableContext.fetchMessages(50)) {
            //         Message msg;
            //         boolean hasMessages = false;

            //         while ((msg = fetchConsumer.nextMessage()) != null) {
            //             hasMessages = true;
            //             byte[] msgData = msg.getData();
            //             JsonNode jsonMessage = Utils.parseAndGetJson(msgData);
            //             LogStore.addLog(jsonMessage);
            //             msg.ack();
            //         }
                    
            //         // send logs to TLC
                    

            //         if (!hasMessages) {
            //             Thread.sleep(100);
            //         }
            //     } catch (Exception e) {
            //         e.printStackTrace();
            //         Thread.sleep(500);
            //     }
            }
        }
    }
