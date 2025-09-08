package tla.monitor.audit;

import java.io.File;
import java.io.IOException;

public class RunTLC {
    static int runTLC(String specFile, String cfgFile, String tlaToolsPath) throws IOException, InterruptedException{
    ProcessBuilder pb = new ProcessBuilder("java", "-cp", tlaToolsPath, "tlc2.TLC",
            "-continue",
            "-config", new File(cfgFile).getAbsolutePath(),
            new File(specFile).getAbsolutePath());
    pb.inheritIO();
    Process process = pb.start();
    int exitCode = process.waitFor();
    System.out.println("TLC exited with code: " + exitCode);
    return exitCode;
    }
}
