# ================================================================
# Stage 1: Build - Compile source code
# ================================================================
FROM maven:3.9-eclipse-temurin-21-alpine AS builder

WORKDIR /build

# Copy pom files first (for dependency caching)
COPY pom.xml ./
COPY common-library/pom.xml ./common-library/
COPY cart/pom.xml ./cart/

# Download dependencies (cached layer)
RUN mvn dependency:go-offline -B || true

# Copy source code
COPY . .

# Build cart JAR (compile common-library first)
RUN mvn -B package -pl cart -am -DskipTests

# ================================================================
# Stage 2: Runtime - Run the JAR
# ================================================================
FROM eclipse-temurin:21-jre-alpine

WORKDIR /app

# Copy JAR from builder stage
COPY --from=builder /build/cart/target/cart*.jar app.jar

EXPOSE 80 8090

ENTRYPOINT ["java", "-jar", "/app.jar"]
