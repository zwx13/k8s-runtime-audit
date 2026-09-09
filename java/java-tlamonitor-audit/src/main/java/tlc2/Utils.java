/**
 * This file is responsible for handling the type conversions
 * between TLA and data saved in NATS. It's necessary because
 * in order to ingest K8s audit logs, they need to be transformed
 * to something that TLA understand. Similarly, to publish alerts
 * or save the checkpoint state in a NATS KV, we need to transform
 * TLA tuples, records, functions to data that NATS understands.
 */
package tlc2;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.core.exc.StreamReadException;
import com.fasterxml.jackson.databind.DatabindException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.BooleanNode;
import com.fasterxml.jackson.databind.node.IntNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.TextNode;

import tlc2.value.IValue;
import tlc2.value.impl.BoolValue;
import tlc2.value.impl.FcnRcdValue;
import tlc2.value.impl.IntValue;
import tlc2.value.impl.RecordValue;
import tlc2.value.impl.SetEnumValue;
import tlc2.value.impl.StringValue;
import tlc2.value.impl.TupleValue;
import tlc2.value.impl.Value;
import util.UniqueString;

public class Utils {
    public static JsonNode parseAndGetJson(byte[] msgData) throws IOException, StreamReadException, DatabindException
    {
    // json parser, hold whole Json in root
    ObjectMapper mapper = new ObjectMapper();
    JsonNode root = mapper.readTree(msgData);

    // String verb = root.get("verb").asText();
    // String pod = root.path("objectRef").path("name").asText();
    // String namespace = root.path("requestObject")
    //                        .path("spec")
    //                        .path("nodeSelector")
    //                        .path("kubernetes.io/hostname")
    //                        .asText();

    // System.out.println("***********************************************************");
    // System.out.println("Received node-per-ns log! Woooooooooooooooo~");
    // System.out.printf("Pod %s was %sd in namespace %s\n", pod, verb, namespace);
    // System.out.println("***********************************************************");

    return root;
    }

    // public static JsonNode getJsonFromValue(IValue value) throws IOException{
    //     JsonNodeType jsonType = JsonNode.getNodeType();
    // } 

    /**
     * 
     * Transforms JSON into a datatype that TLA understands.
     * Arrays become TupleValue. 
     * Normal JSON objects become RecordValue. 
     * Objects marked with:
     *     "__tla_function": true
     * become FcnRcdValue. 
     */
    public static IValue getValueFromJson(JsonNode json) throws IOException {
    return switch (json.getNodeType()) {
        case ARRAY   -> getTupleValue(json);
        case OBJECT  -> {
            if (json.has("__tla_function") && json.get("__tla_function").asBoolean()) {
                yield getFcnRcdValue(json);
            }
            yield getRecordValue(json);
        }
        case NUMBER  -> IntValue.gen(json.asInt());
        case BOOLEAN -> new BoolValue(json.asBoolean());
        case STRING  -> new StringValue(json.asText());
        case NULL    -> null;
        default      -> throw new IOException(
            "Cannot convert the given value; unsupported type: " + json.getNodeType()
        );
    };
}

    // iterate over json kids, not root
    // single TupleValue instance is created at the end, that is the array
    public static TupleValue getTupleValue(JsonNode json) throws IOException{
        List<IValue> elements = new ArrayList<>();
        for (JsonNode element : json) {
            // null elements destroy the tuple, so we skip them
            if (element.isNull()){
                continue;
            }
            elements.add(getValueFromJson(element));
        }
        //  must take array not list
        Value[] arr = elements.toArray(new Value[0]);
        // here we can cast since we know elements are concrete values
        return new TupleValue(arr);

    }

    // here to note that properties() returns an Collections.emptyset()
    // which is a Set. Set extends Collection, that extends Iterable
    // so we can iterate through it
    public static RecordValue getRecordValue(JsonNode json) throws IOException {
        List<UniqueString> keys = new ArrayList<>();
        List<IValue> values = new ArrayList<>();
        for (Map.Entry<String, JsonNode> entry : json.properties()) {
            // null values destroy the record, so we skip them
            if (entry.getValue().isNull()){
                continue;
            }
            keys.add(UniqueString.uniqueStringOf(entry.getKey()));
            values.add(getValueFromJson(entry.getValue()));
        }
        UniqueString[] stringArr = keys.toArray(new UniqueString[0]);
        Value[] valArr = values.toArray(new Value[0]);
        return new RecordValue(stringArr, valArr, false);
    }

    public static FcnRcdValue getFcnRcdValue(JsonNode json) throws IOException {
        JsonNode entries = json.get("entries");

        if (entries == null || !entries.isArray()) {
            throw new IOException("Invalid encoded TLA function: missing entries array");
        }

        List<Value> domain = new ArrayList<>();
        List<Value> values = new ArrayList<>();

        for (JsonNode entry : entries) {
            JsonNode keyJson = entry.get("key");
            JsonNode valueJson = entry.get("value");

            if (keyJson == null || valueJson == null) {
                throw new IOException("Invalid encoded TLA function entry");
            }

            IValue key = getValueFromJson(keyJson);
            IValue value = getValueFromJson(valueJson);

            domain.add((Value) key);
            values.add((Value) value);
        }

        Value[] domainArr = domain.toArray(new Value[0]);
        Value[] valueArr = values.toArray(new Value[0]);

        return new FcnRcdValue(domainArr, valueArr, false);
    }

    public static JsonNode getJsonFromValue(IValue value) throws IOException{
        // System.out.println("TLC value class = " + value.getClass().getName()
        // + " ; printed = " + value);
        if (value instanceof IntValue){
            return IntNode.valueOf(((IntValue) value).val);
        }
        if (value instanceof BoolValue){
            return BooleanNode.valueOf(((BoolValue) value).val);
        }
        if (value instanceof StringValue){
            return TextNode.valueOf(((StringValue) value).val.toString());
        }
        if (value instanceof TupleValue){
            return getArrayNode((TupleValue) value);
        }
        if (value instanceof FcnRcdValue){
            return getJsonFromFcn((FcnRcdValue) value);
        }
        if (value instanceof RecordValue){
            return getObjectNode((RecordValue) value);
        }
        if (value instanceof SetEnumValue) {
            return getArrayNode((SetEnumValue) value);
        }
        else{
            throw new IOException(
                "Cannot convert TLC value to JSON; type="
                + value.getClass().getName()
                + ", value="
                + value
            );
        }
    }

    public static ArrayNode getArrayNode(TupleValue value) throws IOException{
        List<JsonNode> elements = new ArrayList<>();
        for(Value element : value.elems){
            elements.add(getJsonFromValue(element));
        }
        return new ArrayNode(new JsonNodeFactory(false), elements);
    }

    public static ArrayNode getArrayNode(SetEnumValue set) throws IOException {
        ArrayNode array = new ArrayNode(new JsonNodeFactory(false));

        for (int i = 0; i < set.elems.size(); i++) {
            Value element = set.elems.elementAt(i);
            array.add(getJsonFromValue(element));
        }

        return array;
    }

    public static ObjectNode getObjectNode(RecordValue value) throws IOException{
        ObjectNode obj = JsonNodeFactory.instance.objectNode();
        String key;
        JsonNode json;
        for (int i = 0; i < value.names.length; i++){
            key = value.names[i].toString();
            json = (JsonNode) getJsonFromValue(value.values[i]);
            obj.set(key, json);
        }
        return obj;
    }
    
    // 4 FcnRcdValue
    public static ArrayNode getArrayNode(FcnRcdValue f) throws IOException{
        List<JsonNode> elements = new ArrayList<>();
        for(Value element : f.values){
            elements.add(getJsonFromValue(element));
        }
        return new ArrayNode(new JsonNodeFactory(false), elements);
    }

    public static ObjectNode getObjectNode(FcnRcdValue f) throws IOException{
        ObjectNode obj = JsonNodeFactory.instance.objectNode();
        Value k;
        JsonNode json;
        for (int i = 0; i < f.domain.length; i++){
            k = f.domain[i];
            if (!(k instanceof StringValue)) {
                throw new IOException("Cannot convert function to JSON object; non-string key:"
                        + k.getClass().getName() + " printed=" + k);
            }
            String key = ((StringValue) k).val.toString();
            json = (JsonNode) getJsonFromValue((IValue) f.values[i]);
            obj.set(key, json);
        }
        return obj;
    }

    public static JsonNode getJsonFromFcn(FcnRcdValue f) throws IOException{
        ObjectNode obj = JsonNodeFactory.instance.objectNode();
        ArrayNode entries = JsonNodeFactory.instance.arrayNode();

        obj.put("__tla_function", true);

        if (f.domain != null) {
            for (int i = 0; i < f.domain.length; i++) {
                ObjectNode entry = JsonNodeFactory.instance.objectNode();

                entry.set("key", getJsonFromValue(f.domain[i]));
                entry.set("value", getJsonFromValue(f.values[i]));

                entries.add(entry);
            }
        }
        else if (f.intv != null) {
            for (int i = 0; i < f.values.length; i++) {
                ObjectNode entry = JsonNodeFactory.instance.objectNode();

                entry.set("key", IntNode.valueOf(f.intv.low + i));
                entry.set("value", getJsonFromValue(f.values[i]));

                entries.add(entry);
            }
        }
        else {
            throw new IOException("Cannot serialize FcnRcdValue: no domain or interval");
        }

        obj.set("entries", entries);

        return obj;
    }


    /* 
    ****************************
    GET ENV VARS PART
    ****************************
    */

    public static String env(String name, String def) {
        String v = System.getenv(name);
        return (v == null || v.isBlank()) ? def : v.trim();
    }

    public static int envInt(String name, int def) {
        String v = System.getenv(name);
        if (v == null || v.isBlank()) return def;
        try {
            return Integer.parseInt(v.trim());
        }
        catch (NumberFormatException e) {
            throw new RuntimeException("Invalid int env " + name + "=" + v, e);
        }
    }
}