# ================================================================
# Stage 1: Build cart from full project
# ================================================================
FROM maven:3.9-eclipse-temurin-21-alpine AS builder
WORKDIR /app

# Copy FULL project (root pom + all modules needed)
COPY pom.xml ./pom.xml
COPY common-library ./common-library
COPY cart ./cart

# Tạo root pom minimal chỉ với 2 modules cần thiết
# (overwrite pom.xml gốc — không copy modules không liên quan)
RUN printf '<?xml version="1.0" encoding="UTF-8"?>\
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"\
  xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">\
  <modelVersion>4.0.0</modelVersion>\
  <groupId>com.yas</groupId>\
  <artifactId>yas-parent</artifactId>\
  <version>${revision}</version>\
  <packaging>pom</packaging>\
  <properties>\
    <revision>1.0-SNAPSHOT</revision>\
    <java.version>21</java.version>\
    <maven.compiler.source>21</maven.compiler.source>\
    <maven.compiler.target>21</maven.compiler.target>\
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\
  </properties>\
  <modules>\
    <module>common-library</module>\
    <module>cart</module>\
  </modules>\
</project>' > ./pom.xml

# Build cart + common-library (không kéo modules khác)
RUN mvn -B clean package -pl cart -am -DskipTests

# ================================================================
# Stage 2: Runtime
# ================================================================
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=builder /app/cart/target/cart-*.jar app.jar
EXPOSE 80 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:80/actuator/health/liveness || exit 1
ENTRYPOINT ["java", "-jar", "/app.jar"]
