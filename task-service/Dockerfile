# ---- build stage: Maven wrapper + JDK ----
FROM eclipse-temurin:21-jdk AS build
WORKDIR /app
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN chmod +x mvnw
# Download Maven + dependencies into an image layer (not a cache mount) so the layer cache, both
# local and the GitHub Actions cache, skips this step entirely until pom.xml changes.
RUN ./mvnw -B -q dependency:go-offline
COPY src src
RUN ./mvnw -B -q -DskipTests package

# ---- runtime stage: JRE only, non-root ----
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S -G app -u 10001 app
COPY --from=build /app/target/task-service.jar app.jar
USER app
ENV PORT=8002 \
    JAVA_OPTS="-XX:MaxRAMPercentage=60 -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xss512k"
EXPOSE 8002
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=10 \
  CMD wget -qO- "http://localhost:${PORT}/actuator/health" | grep -q '"UP"' || exit 1
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
