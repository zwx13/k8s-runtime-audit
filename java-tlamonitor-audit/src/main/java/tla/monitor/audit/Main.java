package tla.monitor.audit;

import io.nats.client.*;
import io.nats.client.api.ConsumerConfiguration;

import java.io.IOException;
import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.Map;

import com.fasterxml.jackson.databind.ObjectMapper;



public class Main {
    public static void main(String[] args) throws IOException, InterruptedException, JetStreamApiException{
        if (args.length != 3){
            System.out.println("Wrong no. of arguments");
            System.out.println("""
  usage:
  java -cp java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT.jar Main \
     /absolute/path/to/spec.tla \
     /absolute/path/to/template.cfg \
     /absolute/path/to/tla2tools.jar

""");
        }
        String specFile = args[0];
        String cfgFile = args[1];
        String tlaToolsPath = args[2];

        System.out.println("Spec file: " + specFile);
        System.out.println("Config file: " + cfgFile);
        System.out.println("TLC tools path: " + tlaToolsPath);

        RunTLC.runTLC(specFile, cfgFile, tlaToolsPath);
    }
}
