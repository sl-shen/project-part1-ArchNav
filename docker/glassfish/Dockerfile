# ============================================================
# GlassFish 4.1.1 + ArchNav Application
#
# Assignment PDF specifies GlassFish 3.1.2.2 (compatible with ADF 11g / JSF 2.1),
# but 3.1.2.2 cannot run on Java 8 (Felix OSGi crash — Issue #12).
# Build context must be the project root (docker-compose.yml sets context: .)
# ============================================================
FROM eclipse-temurin:8-jdk-jammy

RUN apt-get update && apt-get install -y wget unzip perl python3 && rm -rf /var/lib/apt/lists/*

# ── Download and install GlassFish 4.1.1 (Java 8 compatible, JSF 2.2; replaces 3.1.2.2) ──
RUN wget -q \
    "https://repo1.maven.org/maven2/org/glassfish/main/distributions/glassfish/4.1.1/glassfish-4.1.1.zip" \
    -O /tmp/glassfish.zip && \
    unzip -q /tmp/glassfish.zip -d /opt/ && \
    rm /tmp/glassfish.zip

ENV GLASSFISH_HOME=/opt/glassfish4
ENV PATH=$GLASSFISH_HOME/bin:$PATH

# ── Change GlassFish HTTP port from 8080 to 9999 ──
RUN sed -i 's/port="8080"/port="9999"/g' \
    $GLASSFISH_HOME/glassfish/domains/domain1/config/domain.xml

# ── Re-enable TLS 1.0/1.1 (GlassFish 4 admin listener uses TLS 1.0; disabled by default in Java 8u292+) ──
RUN find /opt/java /usr/lib/jvm -name "java.security" 2>/dev/null | \
    xargs sed -i 's/TLSv1, TLSv1\.1, //' 2>/dev/null || true

# ── Replace GlassFish self-signed certificates (bundled certs expired 2025-09) ──
RUN KEYSTORE=$GLASSFISH_HOME/glassfish/domains/domain1/config/keystore.jks && \
    CACERTS=$GLASSFISH_HOME/glassfish/domains/domain1/config/cacerts.jks && \
    for ALIAS in s1as glassfish-instance; do \
        keytool -delete -alias $ALIAS -keystore $KEYSTORE -storepass changeit 2>/dev/null || true; \
        keytool -genkeypair -alias $ALIAS -keyalg RSA -keysize 2048 -validity 3650 \
            -dname "CN=localhost,OU=GlassFish,O=Eclipse,L=Santa Clara,ST=California,C=US" \
            -keystore $KEYSTORE -storepass changeit -keypass changeit; \
        keytool -export -alias $ALIAS -keystore $KEYSTORE -storepass changeit \
            -file /tmp/$ALIAS.cert; \
        keytool -delete -alias $ALIAS -keystore $CACERTS -storepass changeit 2>/dev/null || true; \
        keytool -import -alias $ALIAS -noprompt -keystore $CACERTS -storepass changeit \
            -file /tmp/$ALIAS.cert; \
        rm -f /tmp/$ALIAS.cert; \
    done && echo "GlassFish certificates renewed ✓"

# ── Download MySQL JDBC driver into GlassFish lib ──
RUN wget -q \
    "https://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.47/mysql-connector-java-5.1.47.jar" \
    -O $GLASSFISH_HOME/glassfish/domains/domain1/lib/mysql-connector-java.jar

# ── Patch WAR: inject fortress.properties, remove ADFGlassFishAppLifeCycleListener ──
COPY docker/glassfish/archemy.war /tmp/original.war
COPY docker/glassfish/fortress.properties /tmp/fortress.properties
COPY docker/glassfish/fix_home.py /tmp/fix_home.py

RUN mkdir -p /tmp/war-patch/WEB-INF/classes /tmp/war-patch/adf-patch /tmp/war-patch/secured && \
    cp /tmp/fortress.properties /tmp/war-patch/WEB-INF/classes/fortress.properties && \
    cp /tmp/original.war /tmp/archemy.war && \
    cd /tmp/war-patch && \
    jar xf /tmp/archemy.war WEB-INF/web.xml WEB-INF/glassfish-web.xml WEB-INF/lib/adf-richclient-impl-11.jar secured/Home.jspx && \
    awk 'BEGIN{skip=0} /<listener>/{buf=$0"\n";skip=1;next} skip{buf=buf$0"\n"; if(/<\/listener>/){if(buf!~/ADFGlassFishAppLifeCycleListener/)printf "%s",buf; skip=0;buf=""};next} {print}' WEB-INF/web.xml > WEB-INF/web.xml.tmp && mv WEB-INF/web.xml.tmp WEB-INF/web.xml && \
    echo "ADFGlassFishAppLifeCycleListener removed" && \
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<glassfish-web-app>\n  <context-root>archemy</context-root>\n</glassfish-web-app>\n' > WEB-INF/glassfish-web.xml && \
    echo "context-root set to archemy" && \
    cd /tmp/war-patch/adf-patch && \
    jar xf /tmp/war-patch/WEB-INF/lib/adf-richclient-impl-11.jar META-INF/faces-config.xml && \
    perl -0777 -i -pe 's/\s*<exception-handler-factory>[^<]*<\/exception-handler-factory>//g' META-INF/faces-config.xml && \
    echo "ADF ExceptionHandlerFactory removed" && \
    jar uf /tmp/war-patch/WEB-INF/lib/adf-richclient-impl-11.jar META-INF/faces-config.xml && \
    cd /tmp/war-patch && \
    sed -i 's/from="  *\//from="\//g' secured/Home.jspx && \
    sed -i 's/action=" "/action=""/g' secured/Home.jspx && \
    sed -i 's/usesUpload="true"/usesUpload="false"/g' secured/Home.jspx && \
    sed -i 's/::cl9 ::cl9/::cl9 ::cl8/g' secured/Home.jspx && \
    python3 /tmp/fix_home.py && \
    echo "Home.jspx patched: spaces, usesUpload, partialTriggers, FortressAllowed fixed" && \
    jar uf /tmp/archemy.war WEB-INF/classes/fortress.properties WEB-INF/web.xml WEB-INF/glassfish-web.xml WEB-INF/lib/adf-richclient-impl-11.jar secured/Home.jspx && \
    mkdir -p $GLASSFISH_HOME/glassfish/domains/domain1/autodeploy && \
    cp /tmp/archemy.war $GLASSFISH_HOME/glassfish/domains/domain1/autodeploy/archemy.war

# ── Copy ADF Essentials modules to GlassFish shared lib (excluding JARs already in the WAR) ──
COPY modules/ /tmp/adf-modules/
# Only copy module JARs absent from the WAR to avoid ADF 12c vs 11g version conflicts
RUN jar tf /tmp/original.war | grep "^WEB-INF/lib/.*\.jar$" | sed 's|WEB-INF/lib/||' | sort > /tmp/war-jar-names.txt && \
    find /tmp/adf-modules -name "*.jar" | while read jarpath; do \
        jarname=$(basename "$jarpath"); \
        if ! grep -qx "$jarname" /tmp/war-jar-names.txt; then \
            cp "$jarpath" $GLASSFISH_HOME/glassfish/domains/domain1/lib/; \
        fi; \
    done && \
    rm -rf /tmp/adf-modules /tmp/war-jar-names.txt

# ── Copy startup script ──
COPY docker/glassfish/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9999 4848

ENTRYPOINT ["/entrypoint.sh"]
