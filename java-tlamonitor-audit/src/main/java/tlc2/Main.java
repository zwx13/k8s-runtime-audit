package tlc2;

import io.nats.client.*;

import java.io.IOException;

public class Main {
    public static void main(String[] args) throws IOException, InterruptedException, JetStreamApiException{
        if (args.length != 3){
            System.out.println("Wrong no. of arguments");
            System.out.println("""
  usage:
  java -cp "java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT-shaded.jar:/absolute/path/to/tla2tools.jar" tla.monitor.audit.Main \
    /absolute/path/to/node_isolation.tla \
    /absolute/path/to/node_isolation.cfg \
    /absolute/path/to/tla2tools.jar &
JAVA_PID=$!
    """);
            System.out.println("""
    where:
        - first argument is the TLA+ spec file
        - second argument is the TLA+ config file
        - third argument is the path to tla2tools.jar (needed for TLC)
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
            while (true)
            {
                int exitCode = RunTLC.runTLC(specFile, cfgFile, tlaToolsPath);
                System.out.println("TLC finished with code: " + exitCode);
                Thread.sleep(1000);
            }
            
        }
        catch (Exception e) {
            System.out.println("Error running TLC: " + e.getMessage());
            e.printStackTrace();
            System.exit(2);
        }
    }
}
