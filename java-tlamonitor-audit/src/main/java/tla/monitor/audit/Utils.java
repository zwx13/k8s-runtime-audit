package tla.monitor.audit;

import java.io.IOException;
import java.util.Map;

import org.eclipse.lsp4j.jsonrpc.messages.Tuple;

import java.util.List;
import java.util.ArrayList;
import java.util.Iterator;

import tlc2.value.IValue;
import tlc2.value.impl.*;
import util.UniqueString;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.IntNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.BooleanNode;
import com.fasterxml.jackson.databind.node.JsonNodeType;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.TextNode;
import com.fasterxml.jackson.core.exc.StreamReadException;
import com.fasterxml.jackson.databind.DatabindException;

public class Utils {
    static JsonNode parseAndGetJson(byte[] msgData) throws IOException, StreamReadException, DatabindException
    {
    // json parser, hold whole Json in root
    ObjectMapper mapper = new ObjectMapper();
    JsonNode root = mapper.readTree(msgData);

    String verb = root.get("verb").asText();
    String pod = root.path("objectRef").path("name").asText();
    String namespace = root.path("requestObject")
                           .path("spec")
                           .path("nodeSelector")
                           .path("kubernetes.io/hostname")
                           .asText();

    System.out.println("***********************************************************");
    System.out.println("Received node-per-ns log! Woooooooooooooooo~");
    System.out.printf("Pod %s was %sd in namespace %s\n", pod, verb, namespace);
    System.out.println("***********************************************************");

    return root;
    }

    // public static JsonNode getJsonFromValue(IValue value) throws IOException{
    //     JsonNodeType jsonType = JsonNode.getNodeType();
    // } 

    // call would be like IValue root = getValueFromJson(jsonNodeRoot), sees it s an array
    public static Value getValueFromJson(JsonNode json) throws IOException {
    return switch (json.getNodeType()) {
        case ARRAY   -> getTupleValue(json);
        case OBJECT  -> getRecordValue(json);
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
        List<Value> values = new ArrayList<>();
        for (Map.Entry<String, JsonNode> entry : json.properties()) {
            keys.add(UniqueString.uniqueStringOf(entry.getKey()));
            values.add(getValueFromJson(entry.getValue()));
        }

        UniqueString[] stringArr = keys.toArray(new UniqueString[0]);
        Value[] valArr = values.toArray(new Value[0]);

        return new RecordValue(stringArr, valArr, false);

    }

    public static JsonNode getJsonFromValue(IValue value){
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
        if (value instanceof RecordValue){
            return getObjectNode((RecordValue) value);
        }
        else{
            throw new IOException("Cannot convert value, it is of unknown type")
        }
    }

    public static ArrayNode getArrayNode(TupleValue value){
        List<JsonNode> elements = new ArrayList<>();
        for(Value element : value.elems){
            elements.add(getJsonFromValue(element));
        }
        return new ArrayNode(new JsonNodeFactory(false), elements);
    }

    public static ObjectNode getObjectNode(RecordValue value){
        ObjectNode obj = JsonNodeFactory.instance.objectNode();
        String key;
        JsonNode json;
        for (int i = 0; i < value.names.length; i++){
            key = value.names[i].toString();
            json = (JsonNode) getJsonFromValue(value.values[i]);
            // this has a return value but we ignore it
            obj.set(key, json);
        }
        return obj;
    }
}
