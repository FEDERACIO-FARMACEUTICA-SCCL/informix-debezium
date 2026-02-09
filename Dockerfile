FROM quay.io/debezium/server:3.4.1.Final

USER root

# Add IBM Informix JDBC driver (version matching Debezium 3.4.1.Final)
ADD --chmod=644 https://repo1.maven.org/maven2/com/ibm/informix/jdbc/4.50.12/jdbc-4.50.12.jar /debezium/lib/ifx-jdbc-4.50.12.jar

# Add Informix Change Streams API client (version matching Debezium 3.4.1.Final)
ADD --chmod=644 https://repo1.maven.org/maven2/com/ibm/informix/ifx-changestream-client/1.1.3/ifx-changestream-client-1.1.3.jar /debezium/lib/ifx-changestream-client-1.1.3.jar

# BSON dependency required by Informix JDBC driver
ADD --chmod=644 https://repo1.maven.org/maven2/org/mongodb/bson/3.8.0/bson-3.8.0.jar /debezium/lib/bson-3.8.0.jar

# Remove incompatible JDBC driver if previously added
RUN rm -f /debezium/lib/ifx-jdbc-15.0.1.0.jar /debezium/lib/ifx-changestream-client-1.1.1.jar 2>/dev/null || true

USER 185
