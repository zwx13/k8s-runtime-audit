/**
 * Main entry point for running the TLC model checker with a given TLA+ spec and config file.
 * The class parses cmd arguments, validates the inputs, and repeatedly invokes TLC using the 
 * provided {@code tla2tools.jar}. It also initializes the NATS infra used by the monitoring layer.
 * TLC is executed in a loop; after each run, the process sleeps before restarting TLC. 
 * Any fatal error causes the program to terminate with a non-zero exit code.
 */
package tlc2;

import tlc2.Utils;

import io.nats.client.*;

import java.io.IOException;
import java.io.File;

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

        File readyFile = new File("/tmp/readyz");
        readyFile.createNewFile();

        // start daemon thread that dies
        // when main dies
        Thread.startVirtualThread(() -> {
            File liveFile = new File("/tmp/livez");
            while (true) {
                try {
                    if (!liveFile.exists()) {
                        liveFile.createNewFile();
                    }
                    liveFile.setLastModified(System.currentTimeMillis());

                    Thread.sleep(1000);
                } catch (InterruptedException e) {
                    break;
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }
        });

        try {
            while (true)
            {
                String selfDetectPath = Main.class.getProtectionDomain()
                                            .getCodeSource().getLocation().getPath();
                selfDetectPath = java.net.URLDecoder.decode(selfDetectPath, "UTF-8");

                String overridesJar = Utils.env("MONITOR_JAR_PATH", selfDetectPath);

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
