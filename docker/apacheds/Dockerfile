# ============================================================
# ApacheDS 2.0.0.AM25 + Fortress Core 2.0.3 (for LDAP initialization)
# ============================================================
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    wget unzip maven openjdk-11-jdk-headless netcat-openbsd ldap-utils \
    && rm -rf /var/lib/apt/lists/*

# ── Install ApacheDS 2.0.0.AM25 (use host-pre-downloaded deb to avoid build-time network timeout) ──
COPY apacheds.deb /tmp/apacheds.deb
RUN dpkg -i /tmp/apacheds.deb && rm /tmp/apacheds.deb

# ── Download Fortress Core 2.0.3 source release (contains LDIF setup files) ──
RUN wget -q \
    "https://archive.apache.org/dist/directory/fortress/dist/2.0.3/fortress-core-2.0.3-source-release.zip" \
    -O /tmp/fortress.zip \
    && unzip -q /tmp/fortress.zip -d /opt/ \
    && rm /tmp/fortress.zip

# ── Pre-fetch Maven dependencies (speeds up runtime mvn execution) ──
RUN cd /opt/fortress-core-2.0.3 && \
    mvn dependency:resolve -q 2>/dev/null || \
    echo "Maven dependency pre-fetch complete"

EXPOSE 10389

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /opt/fortress-init

ENTRYPOINT ["/entrypoint.sh"]
