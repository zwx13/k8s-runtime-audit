# k8s-runtime-audit

This repository contains the source code for a Kubernetes multitenancy monitoring tool using TLA+.

The tool monitors Kubernetes audit logs, filters the relevant multitenancy events, stores state through NATS JetStream, runs TLC-based trace checking against a TLA+ trace specification, and outputs alerts when it identifies violations in a NATS Jetstream stream.

## Repository structure

The repository is organized into the following main folders:

- `java`
- `python`
- `tla_specs`
- `k8s`
- `tlc-audit-app`

There is also a `docker-compose.yaml` file in the root of the repository, which can be used for running the main containers locally.

## Java application

The `java` folder contains the TLC runner application.

It includes:

- `pom` files for specifying Java dependencies;
- `src/main/java/tlc2/Main.java`, which runs the application loop. Each iteration launches its own TLC process;
- `src/main/java/tlc2/RunTLC.java`, which starts the TLC process. It takes the specification, `.cfg` file, and `MC*.tla` file as arguments;
- `src/main/java/tlc2/Utils.java`, which contains auxiliary functions for transforming JSON to TLA+ objects and vice versa, along with other helpers;
- `src/main/java/tlc2/overrides/NatsOps.java`, which defines the custom TLC operators needed for ingesting traces from NATS;
- `src/main/java/tlc2/overrides/TLCOverrides.java`, which is required by TLC in order to load the custom operators;
- a `Dockerfile` for containerizing the Java application.

## Python applications

The `python` folder contains the Python applications used for receiving audit logs, filtering them, storing state, and initializing NATS resources.

Inside the `python/python_audit` subfolder:

- `alerts.py` creates the NATS JetStream alerts stream;
- `audit_webhook_receiver.py` creates the webhook used by the Kubernetes API server to send audit logs;
- `classifier.py` contains logic for classifying audit logs;
- `config_helpers.py` contains helpers for reading configuration from environment variables;
- `mt_state_bootstrap.py` is used when the application is deployed or restarted. Its purpose is to catch up the monitoring tool's state with the current cluster state;
- `mt_state_store.py` creates the Key/Value storage in NATS JetStream;
- `multitenancy.py` creates or updates the multitenancy stream, where relevant logs are placed after being filtered from the raw audit stream;
- `stream_functions.py` contains functions that create or update streams, consumers, and Key/Value stores;
- `utils.py` contains helper functions for maintaining the NATS connection and updating liveness checks.

The `python` folder also contains:

- a `Dockerfile` for containerizing the Python applications;
- a `requirements.txt` file containing the Python dependencies.

## TLA+ specifications

The `tla_specs` folder contains the TLA+ specifications used by the tool.

The `NatsSmokeSpec` subfolder contains a small specification that can be run to test that the custom NATS operators work correctly.

The `UpdatedMTSpec` subfolder contains the multitenancy specifications:

- `MT_Audit_RBAC_Base_1.tla` is the base specification. It describes the desired state of the multitenant model;
- `MC_MT_Audit_RBAC_Base_1.tla` and `MC_MT_Audit_RBAC_Base_1.cfg` are the model-checking module and configuration file for the base specification. They contain information about constants, invariants, and other TLC configuration;
- `MT_Audit_RBAC_Trace_1.tla` is the trace specification. It ingests traces and uses predicates from the base specification to evaluate whether the observed behavior is valid;
- `MC_MT_Audit_RBAC_Trace_1.tla` and `MC_MT_Audit_RBAC_Trace_1.cfg` play the same role for the trace specification as the `MC_MT_Audit_RBAC_Base_1.tla` and `MC_MT_Audit_RBAC_Base_1.cfg` files do for the base specification;
- `NatsOps.tla` is a stub module used for loading the custom NATS operators. The actual definitions are implemented in `NatsOps.java`.

The TLA+ specifications can be model checked manually from the TLA+ Toolbox or from VS Code. The trace specification can also be run manually, but the audit webhook and NATS setup need to be running first if live traces are expected.

## TLA+ dependencies

The repository also contains TLA+ dependencies required by the Java checker.

The `tla2tools.jar` file is the TLC binary used to run the model checker. The `CommunityModules` folder contains additional TLA+ operators defined by the community. These modules are available from the TLA+ Community Modules repository:

https://github.com/tlaplus/CommunityModules

Both `tla2tools.jar` and the required community modules must be available when running the Java checker. They are kept in the repository so the checker can load the TLC binary and any additional operators needed by the specifications.

## Local execution with Docker Compose

The root of the repository contains a `docker-compose.yaml` file.

It can be used to initialize the main containers locally:

```bash
docker-compose up
````

To stop them:

```bash
docker-compose down
```

This option is useful for local testing of the individual services without deploying the full Helm chart.

NATS must be available for the tool to work. In the local setup, I used a Docker container with the official NATS image.

## Manual execution without Helm

Parts of the system can also be run manually.

The Python audit webhook can be started with:

```bash
uvicorn audit_webhook_receiver:app --port <port>
```

Other Python scripts can be run with:

```bash
python <script>
```

For example, the scripts that create streams, consumers, alerts, and Key/Value stores may be run manually when testing the system step by step.

The Java TLC runner can also be run manually, but it expects the TLA+ specification, the generated model-checking module, and the configuration file to be provided as arguments. The actual usage prompt is available in the file.

This manual setup is useful when checking that traces are ingested correctly and that the custom TLC operators can communicate with NATS.

## Kubernetes manifests

The `k8s` folder contains the YAML files for deploying the application to a Kubernetes cluster. It is split into several subfolders:

- `cluster-setup`
- `java-runner`
- `nats`
- `python-runners`

The `cluster-setup` subfolder contains files that are additional to the main application deployment. These are part of the actual cluster configuration that was applied in the local test cluster. A cluster where this tool is deployed should be configured in a similar way.

The `java-runner` subfolder contains `java-audit-deployment.yaml`, which defines how the Java TLC runner is deployed.

The `nats` subfolder contains the NATS JetStream setup. This is predefined, but it still needs a persistent volume and a `values.yaml` configuration.

The `python-runners` subfolder contains the Kubernetes resources for the Python components:

- a job for creating the alerts stream;
- a `ClusterRole`, `ClusterRoleBinding`, `ServiceAccount`, and job for the Key/Value bootstrap, since it needs to read the cluster state when initialized;
- a deployment for the multitenancy processor, since it needs to run continuously;
- a deployment and service for the audit webhook, since the Kubernetes API server needs a stable address to send audit logs to.

## Helm deployment

The `tlc-audit-app` folder contains the Helm chart for deploying the application.

It contains a `values.yaml` file, which should be overwritten or adjusted with the actual preferred configuration.

The `Chart.yaml` file shows the NATS dependency. The `Chart.lock` file contains the resolved dependency information. The `templates` folder contains Kubernetes manifests similar to those in the `k8s` folder, but adapted for Helm deployment.

The chart can be deployed with:

```bash
helm upgrade tlc-audit-release tlc-audit-app/ --values tlc-audit-app/values.yaml
```

## Experiments

The `experiment` folder contains the scripts and collected results used for testing the tool against several violating scenarios.

It is split into two subfolders:

- `experiment-scripts`
- `experiment-results`

### Experiment scripts

The `experiment-scripts` subfolder contains the shell scripts used to trigger different multitenancy violations in the cluster.

The scripts are:

- `01-cross-tenant-access.sh`
- `02-dangling-rolebinding.sh`
- `03-rolebinding-to-cluster-admin.sh`
- `04-clusterrolebinding-to-tenant-group.sh`
- `05-dangling-clusterrolebinding.sh`
- `06-combined-scenario.sh`

The `common.sh` file contains helper functions used by the experiment scripts. These include functions for purging the alert stream, subscribing to it, ensuring that the required tenants exist, and other shared setup or cleanup logic.

Each experiment script creates or attempts a specific violating configuration. The one attempted by the `06-combined-scenario` is randomized. The purpose is to check whether the monitoring pipeline detects the violation and produces the expected alert.

### Experiment results

The `experiment-results` subfolder contains the collected results for the experiment runs.

It contains subfolders from `01` to `06`, corresponding to the six experiment scenarios. Each of these folders contains six result subfolders. The name of each result subfolder is `run-` followed by a timestamp representing the run date and time.

Each result subfolder contains:

- `audit-events.jsonl`
- `script-output-and-alerts.log`

The `audit-events.jsonl` file contains the actual violating audit events identified from the cluster.

The `script-output-and-alerts.log` file contains both the output of the experiment script and the output read from the NATS alert stream. The scripts write their output to a temporary file and then print it so the user can inspect what happened during the run.

The violating audit log entry is identified using the `auditID` from the alert. The full audit event is not stored directly in the alert stream because the complete audit log entry is too verbose. Instead, the alert contains enough information for the administrator to locate the corresponding audit event by its `auditID`.

## Kubernetes audit logging requirements

This tool depends on Kubernetes audit logs.

The Kubernetes API server must be configured to send audit logs to the audit webhook. This usually requires changes to the API server audit configuration, including the audit policy and webhook backend configuration.

Because of this, the tool will most likely not work as-is on managed Kubernetes clusters where the user does not have access to API server configuration or audit log forwarding. It is better suited for local clusters, self-managed clusters, or environments where the API server audit configuration can be modified.

## Notes

Multitenancy varies between clusters. Different clusters may use different isolation rules, access-control assumptions, and administrative structures. The included specification models one representative soft multitenancy setup, not every possible Kubernetes multitenancy configuration.

The specifications may be adapted to other multitenancy models. The custom TLC operators and the NATS-based trace ingestion logic may also be reused independently of the specific multitenancy policy.
