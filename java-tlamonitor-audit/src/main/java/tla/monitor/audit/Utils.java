package tla.monitor.audit;

import java.io.IOException;
import java.util.Map;

import com.fasterxml.jackson.core.exc.StreamReadException;
import com.fasterxml.jackson.databind.DatabindException;
import com.fasterxml.jackson.databind.ObjectMapper;



public class Utils {
    static void parseJson(byte[] msgData) throws IOException, StreamReadException, DatabindException
    {
            // json parser
    ObjectMapper mapper = new ObjectMapper();
    Map<String, Object> json = mapper.readValue(msgData, Map.class);
    String verb = (String) json.get("verb");
    Map<String, Object> objectRef = (Map<String, Object>) json.get("objectRef");
    String pod = (String) objectRef.get("name");
    Map<String, Object> requestObject = (Map<String, Object>) json.get("requestObject");
    Map<String, Object> spec = (Map<String, Object>) requestObject.get("spec");
    Map<String, Object> nodeSelector = (Map<String, Object>) spec.get("nodeSelector");
    String namespace = (String) nodeSelector.get("kubernetes.io/hostname");


    System.out.println("***********************************************************");
    System.out.println("Received node-per-ns log! Woooooooooooooooo~");
    System.out.printf("Pod %s was %sd in namespace %s\n", pod, verb, namespace);
    System.out.println("***********************************************************");
    }
}
