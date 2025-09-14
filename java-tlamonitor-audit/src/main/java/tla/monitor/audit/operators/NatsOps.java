package tla.monitor.audit.operators;

import tla.monitor.audit.LogStore;
import tla.monitor.audit.Utils;
import tlc2.overrides.TLAPlusOperator;
import tlc2.value.IValue;
import tlc2.value.impl.*;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;

// operator that takes the batch of 50 logs and then transforms it 
// first the entries, then wraps everything in an ARRAY thingn implementation
// of IValue an IValue? E.g. Tuple, record

public class NatsOps {
    @TLAPlusOperator(identifier = "NatsConsume", module = "NatsOps")
    public static synchronized TupleValue takeFromArray() throws IOException{
        List<JsonNode> inMemoryNodes = LogStore.getLogs();
        List<IValue> collected = new ArrayList<>();
        for (JsonNode element : inMemoryNodes){
            Value value = (Value) Utils.getValueFromJson(element);
            collected.add(value);
        }
        LogStore.clearLogs();
        return new TupleValue(collected.toArray(new Value[0]));
    }
}
