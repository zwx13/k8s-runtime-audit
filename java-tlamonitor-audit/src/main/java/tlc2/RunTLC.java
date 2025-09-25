package tlc2;

import java.io.File;
import java.io.IOException;

import io.nats.client.JetStreamApiException;

public class RunTLC {
    static int runTLC(String specFile, String cfgFile, String tlaToolsPath) throws IOException, InterruptedException, JetStreamApiException{
    ProcessBuilder pb = new ProcessBuilder(
    "java",
    "-cp", tlaToolsPath,
    "-DTLA-Library=/home/malina/monitoring2k25/java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT.jar",
    "tlc2.TLC",
    "-continue",
    "-config", new File(cfgFile).getAbsolutePath(),
    new File(specFile).getAbsolutePath()
);

    pb.inheritIO();
    Process process = pb.start();
    int exitCode = process.waitFor();
    System.out.println("TLC exited with code: " + exitCode);
    return exitCode;
    }
}
