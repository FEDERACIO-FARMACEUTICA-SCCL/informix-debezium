FROM quay.io/debezium/server:3.4.1.Final

USER root

# Add IBM Informix JDBC driver (version matching Debezium 3.4.1.Final)
ADD --chmod=644 https://repo1.maven.org/maven2/com/ibm/informix/jdbc/4.50.12/jdbc-4.50.12.jar /debezium/lib/ifx-jdbc-4.50.12.jar

# Add Informix Change Streams API client (version matching Debezium 3.4.1.Final)
ADD --chmod=644 https://repo1.maven.org/maven2/com/ibm/informix/ifx-changestream-client/1.1.3/ifx-changestream-client-1.1.3.jar /debezium/lib/ifx-changestream-client-1.1.3.jar

# BSON dependency required by Informix JDBC driver
ADD --chmod=644 https://repo1.maven.org/maven2/org/mongodb/bson/3.8.0/bson-3.8.0.jar /debezium/lib/bson-3.8.0.jar

# Verify JAR integrity (SHA1 checksums from Maven Central)
RUN echo "d9466c193f02e2a8111b10c276f168bf37670a1b  /debezium/lib/ifx-jdbc-4.50.12.jar" > /tmp/checksums.txt && \
    echo "f29425c945b0157ff1417acc3fc8ac7f00f569ba  /debezium/lib/ifx-changestream-client-1.1.3.jar" >> /tmp/checksums.txt && \
    echo "1d9b45aa89f7a6ffa93cfd5657920ec4bd8365f0  /debezium/lib/bson-3.8.0.jar" >> /tmp/checksums.txt && \
    sha1sum -c /tmp/checksums.txt && \
    rm /tmp/checksums.txt

# Remove incompatible JDBC driver if previously added
RUN rm -f /debezium/lib/ifx-jdbc-15.0.1.0.jar /debezium/lib/ifx-changestream-client-1.1.1.jar 2>/dev/null || true

USER 185
