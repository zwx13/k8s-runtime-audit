package tla.monitor.audit;

import java.util.ArrayList;
import java.util.List;
import com.fasterxml.jackson.databind.JsonNode;


public class LogStore {
    // initialization with no constructor since we do not plan
    // to create an instance of this class
    // but just to use it as a global variable
    private static List<JsonNode> logList = new ArrayList<>(50);

    // avoid default constructor
    private LogStore() { }

    public static void addLog(JsonNode log){
        logList.add(log);
    }

    public static List<JsonNode> getLogs(){
        return new ArrayList<>(logList);
    }

    public static void clearLogs(){
        logList.clear();
    }

}
