package tlc2;

import io.nats.client.*;

import java.io.IOException;

/**
 * Main entry point for running the TLC model checker with a given TLA+ spec and config file.
 * <p>
 * The class parses cmd arguments, validates the inputs, and repeatedly invokes TLC using the 
 * provided {@code tla2tools.jar}. It also initializes the NATS infra used by the monitoring layer.
 * </p>
 *
 * <h2>Command-line arguments</h2>
 * <ol>
 *   <li>Absolute path to the TLA+ specification file ({@code .tla})</li>
 *   <li>Absolute path to the TLC configuration file ({@code .cfg})</li>
 *   <li>Absolute path to {@code CommunityModules.jar}</li>
 *   <li>Absolute path to {@code tla2tools.jar}</li>
 * </ol>
 *
 * <h2>Usage</h2>
 * <pre>{@code
 * java -cp "java-tlamonitor-audit-1.0-SNAPSHOT-shaded.jar:/path/to/tla2tools.jar" \
 *   tlc2.Main \
 *   /path/to/spec.tla \
 *   /path/to/spec.cfg \
 *   /path/to/CommunityModules.jar \
 *   /path/to/tla2tools.jar
 * }</pre>
 *
 * <p>
 * TLC is executed in a loop; after each run, the process sleeps before restarting TLC. 
 * Any fatal error causes the program to terminate with a non-zero exit code.
 * </p>
 */

public class Main {
    public static void main(String[] args) throws IOException, InterruptedException, JetStreamApiException{
        if (args.length != 4){
            System.out.println("Wrong no. of arguments");
            System.out.println("""
  usage:
  java -cp "java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT-shaded.jar:/absolute/path/to/tla2tools.jar" tla.monitor.audit.Main \
    /absolute/path/to/*.tla \
    /absolute/path/to/*.cfg \
    /absolute/path/to/CommunityModules.jar \
    /absolute/path/to/tla2tools.jar &
JAVA_PID=$!
    """);
            System.out.println("""
    where:
        - 1st argument is the TLA+ spec file
        - 2nd argument is the TLA+ config file
        - 3rd argument is the path to CommunityModules.jar
        - 4th argument is the path to tla2tools.jar (needed for TLC)
""");
           System.exit(1);
        }
        String specFile = args[0];
        String cfgFile = args[1];
        String communityModules = args[2];
        String tlaToolsPath = args[3];

        System.out.println("Spec file: " + specFile);
        System.out.println("Config file: " + cfgFile);
        System.out.println("Community Modules path: " + communityModules);
        System.out.println("TLC tools path: " + tlaToolsPath);

        try {
            while (true)
            {
                String overridesJar = "java/java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT.jar";
                int exitCode = RunTLC.runTLC(specFile, cfgFile, tlaToolsPath, communityModules, overridesJar);
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
