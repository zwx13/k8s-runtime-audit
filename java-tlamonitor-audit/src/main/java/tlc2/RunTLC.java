package tlc2;

import java.io.File;
import java.io.IOException;

import io.nats.client.JetStreamApiException;

public class RunTLC {
    static int runTLC(String specFile, String cfgFile, String tlaToolsPath, String overridesJar) throws IOException, InterruptedException, JetStreamApiException{
    String tlaToolsPathAbs = new File(tlaToolsPath).getAbsolutePath();
    String overridesAbs = new File(overridesJar).getAbsolutePath();
    String cfgAbs = new File(cfgFile).getAbsolutePath();
    String specAbs = new File(specFile).getAbsolutePath();

    ProcessBuilder pb = new ProcessBuilder(
    "java",
    "-cp", tlaToolsPathAbs + ":" + overridesAbs,
    "-DTLA-Library=" + overridesAbs,
    "tlc2.TLC",
    "-continue",
    "-config", cfgAbs,
    specAbs
);

    pb.inheritIO();

    // debug
    System.out.println(String.join(" ", pb.command()));

    Process process = pb.start();
    int exitCode = process.waitFor();

    System.out.println("TLC exited with code: " + exitCode);
    return exitCode;
    }
}
