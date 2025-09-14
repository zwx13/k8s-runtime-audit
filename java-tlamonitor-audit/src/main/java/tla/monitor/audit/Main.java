package tla.monitor.audit;

import io.nats.client.*;

import java.io.IOException;

public class Main {
    public static void main(String[] args) throws IOException, InterruptedException, JetStreamApiException{
        if (args.length != 3){
            System.out.println("Wrong no. of arguments");
            System.out.println("""
  usage:
  java -cp /absolute/path/to/project/jar Main \
     /absolute/path/to/spec.tla \
     /absolute/path/to/template.cfg \
     /absolute/path/to/tla2tools.jar

""");
           System.exit(1);
        }
        String specFile = args[0];
        String cfgFile = args[1];
        String tlaToolsPath = args[2];

        System.out.println("Spec file: " + specFile);
        System.out.println("Config file: " + cfgFile);
        System.out.println("TLC tools path: " + tlaToolsPath);

        try {
            NatsManager nm = new NatsManager();
            int exitCode = RunTLC.runTLC(specFile, cfgFile, tlaToolsPath);
            System.out.println("TLC finished with code: " + exitCode);
        }
        catch (Exception e) {
            System.out.println("Error running TLC: " + e.getMessage());
            e.printStackTrace();
            System.exit(2);
        }
    }
}
