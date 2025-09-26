package tlc2;

import java.io.File;
import java.io.IOException;

import io.nats.client.JetStreamApiException;

public class RunTLC {
    static int runTLC(String specFile, String cfgFile, String tlaToolsPath, String overridesJar) throws IOException, InterruptedException, JetStreamApiException{
    ProcessBuilder pb = new ProcessBuilder(
    "java",
    "-cp", tlaToolsPath + ":" + overridesJar,
    "-DTLA-Library=" + overridesJar,
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
