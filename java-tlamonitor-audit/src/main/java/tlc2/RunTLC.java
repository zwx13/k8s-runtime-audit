package tlc2;

import java.io.File;
import java.io.IOException;
import java.io.BufferedReader;
import java.io.InputStreamReader;

import io.nats.client.JetStreamApiException;

public class RunTLC {
    static int runTLC(String specFile, String cfgFile, String tlaToolsPath, String communityModules, String overridesJar) throws IOException, InterruptedException, JetStreamApiException{
    
    String sep = File.pathSeparator;

    String tlaToolsPathAbs = new File(tlaToolsPath).getAbsolutePath();
    String overridesAbs = new File(overridesJar).getAbsolutePath();
    String communityModulesAbs = new File(communityModules).getAbsolutePath();
    String cfgAbs = new File(cfgFile).getAbsolutePath();
    String specAbs = new File(specFile).getAbsolutePath();

    ProcessBuilder pb = new ProcessBuilder(
    "java",
    "-XX:+UseParallelGC",
    "-cp", overridesAbs + sep + tlaToolsPathAbs + sep + communityModulesAbs,
    "-DTLA-Library=" + overridesAbs + sep + communityModulesAbs,
    "tlc2.TLC",
    "-config", cfgAbs,
    specAbs
);

    // pb.inheritIO();

    // debug
    // System.out.println(String.join(" ", pb.command()));

    pb.redirectErrorStream(true);
    Process process = pb.start();

    try (BufferedReader r = new BufferedReader (new InputStreamReader (process.getInputStream()))) {
        String line;
        while ((line = r.readLine()) != null) {
            if (line.startsWith("Parsing file ")) continue;
            if (line.startsWith("Semantic processing of module ")) continue;
            if (line.startsWith("Linting of module ")) continue;
            if (line.startsWith("Loading ")) continue;
            System.out.println(line);
        }
    }

    int exitCode = process.waitFor();

    if (exitCode != 0) {
        System.out.println("TLC failed. Command: " + String.join(" ", pb.command()));
    }
    return exitCode;
    }
}
