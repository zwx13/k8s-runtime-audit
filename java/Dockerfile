# build the app
FROM maven:3.9.8-eclipse-temurin-21 AS build
WORKDIR /build

COPY tla2tools.jar /build/

RUN mvn install:install-file \
    -Dfile=/build/tla2tools.jar \
    -DgroupId=tla.monitor \
    -DartifactId=tla2tools \
    -Dversion=1.8.0 \
    -Dpackaging=jar

COPY java/java-tlamonitor-audit/ java/java-tlamonitor-audit/

WORKDIR /build/java/java-tlamonitor-audit/

RUN mvn clean package -DskipTests

# final runtime image
FROM eclipse-temurin:21-jre-jammy
WORKDIR /app

COPY --from=build /build/java/java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT.jar ./app.jar

COPY tla2tools.jar ./
COPY CommunityModules.jar ./
COPY tla_specs/ ./tla_specs/

CMD ["java", "-cp", "app.jar:CommunityModules.jar:tla2tools.jar", "tlc2.Main", \
     "tla_specs/MTSpec/MC_MT_Audit_RBAC_Trace_Extended.tla", \
     "tla_specs/MTSpec/MC_MT_Audit_RBAC_Trace_Extended.cfg", \
     "CommunityModules.jar", \
     "tla2tools.jar"]