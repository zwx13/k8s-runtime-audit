/**
 * This file handles creation of TLC processes. It's responsible for
 * passing the right arguments and filtering the output to contain only
 * relevant information.
 */

package tlc2;

import java.io.File;
import java.io.IOException;
import java.io.BufferedReader;
import java.io.InputStreamReader;

import io.nats.client.JetStreamApiException;

public class RunTLC {

    static int runTLC(
        String specFile,
        String cfgFile,
        String tlaToolsPath,
        String communityModules,
        String overridesJar
    ) throws IOException, InterruptedException, JetStreamApiException {

        String sep = File.pathSeparator;

        String tlaToolsPathAbs = new File(tlaToolsPath).getAbsolutePath();
        String overridesAbs = new File(overridesJar).getAbsolutePath();
        String communityModulesAbs = new File(communityModules).getAbsolutePath();
        String cfgAbs = new File(cfgFile).getAbsolutePath();
        String specAbs =new File(specFile).getAbsolutePath();
        String tlaMetaDir =System.getenv().getOrDefault("TLA_META_DIR", "/app/tla_states");

        ProcessBuilder pb = new ProcessBuilder(
            "java",
            "-XX:+UseParallelGC",

            "-cp",
            overridesAbs
                + sep
                + tlaToolsPathAbs
                + sep
                + communityModulesAbs,

            "-DTLA-Library="
                + overridesAbs
                + sep
                + communityModulesAbs,

            "tlc2.TLC",

            "-metadir",
            tlaMetaDir,

            "-teSpecOutDir",
            tlaMetaDir,

            "-config",
            cfgAbs,

            specAbs
        );

        pb.redirectErrorStream(true);

        long start = System.nanoTime();

        Process process = pb.start();

        int batchSize = 0;
        double fetchMs = 0.0;

        String metricsFile = null;

        File marker = new File("/experiment-results/.mt-experiment-active");

        try (BufferedReader r = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            String line;

            while ((line = r.readLine()) != null) {

                if (line.startsWith("MT_METRIC")) {

                    String[] parts = line.split("\\s+");

                    for (String part : parts) {

                        if (part.startsWith("batchSize=")) {
                            batchSize = Integer.parseInt(part.substring("batchSize=".length()));
                        }
                        else if (part.startsWith("fetchMs=")) {
                            fetchMs = Double.parseDouble(part.substring("fetchMs=".length()));
                        }
                    }

                    if (batchSize > 0) {
                        try {
                            String path = java.nio.file.Files.readString(marker.toPath()).trim();

                            if (!path.isEmpty()) {
                                metricsFile = path;
                            }
                        }
                        catch (java.nio.file.NoSuchFileException e) {
                            /*
                             * No active experiment, or the experiment
                             * ended between batch fetch and marker read.
                             */
                            metricsFile = null;
                        }
                    }

                    continue;
                }

                if (line.startsWith("Parsing file ")) {
                    continue;
                }

                if (line.startsWith("Semantic processing of module ")) {
                    continue;
                }

                if (line.startsWith("Linting of module ")) {
                    continue;
                }

                if (line.startsWith("Loading ")) {
                    continue;
                }

                System.out.println(line);
            }
        }

        int exitCode = process.waitFor();

        long end = System.nanoTime();

        double durationMs = (end - start) / 1_000_000.0;

        double nonFetchMs = durationMs - fetchMs;

        /*
         * Write metrics even if the experiment marker has already been
         * removed, because metricsFile was captured when the batch was
         * fetched.
         */
        if (metricsFile != null && batchSize > 0) {

            File file = new File(metricsFile);

            try (
                java.io.FileWriter fw = new java.io.FileWriter(file, true);

                java.io.PrintWriter out = new java.io.PrintWriter(fw)
            ) {
                out.printf(
                    java.util.Locale.US,
                    "%s,%d,%.3f,%.3f,%.3f,%d%n",
                    java.time.Instant.now(),
                    batchSize,
                    fetchMs,
                    durationMs,
                    nonFetchMs,
                    exitCode
                );
            }
        }
        
        /* 
         * NatsOps creates this marker whenever it consumes,
         * so we make sure to always delete it after TLC finishes
        */
        if (batchSize > 0) {
            File markerActive = new File("/experiment-results/.mt-tlc-batch-active");
            java.nio.file.Files.deleteIfExists(markerActive.toPath());
        }

        if (exitCode != 0) {
            System.out.println("TLC failed. Command: " + String.join(" ", pb.command()));
        }

        return exitCode;
    }
}
