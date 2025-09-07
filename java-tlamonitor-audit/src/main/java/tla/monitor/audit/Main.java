package tla.monitor.audit;

import io.nats.client.*;
import io.nats.client.api.ConsumerConfiguration;

import java.io.IOException;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.Map;

import com.fasterxml.jackson.databind.ObjectMapper;

/* Purpose of this file is to consume from the audit.node.per.tenant subject (with durable)
 * and send the consumed logs to tlc. Logs should be persistent and when we stop the scripts,
 * and then turn back on again, the index should be preserved so we use
 * a durable consumer
 */

public class Main {
    
}
