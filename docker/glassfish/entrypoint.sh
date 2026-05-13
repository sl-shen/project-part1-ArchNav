#!/bin/bash

GLASSFISH_HOME=/opt/glassfish4
LOG="$GLASSFISH_HOME/glassfish/domains/domain1/logs/server.log"
# GlassFish 4 default admin password is empty; create passwordfile so asadmin doesn't prompt
PWFILE=$(mktemp)
echo "AS_ADMIN_PASSWORD=" > "$PWFILE"
ASADMIN="$GLASSFISH_HOME/bin/asadmin --user admin --passwordfile $PWFILE"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ─────────────────────────────────────────────────────────────
# 1. Start GlassFish domain
# ─────────────────────────────────────────────────────────────
log "Starting GlassFish 4.1.1..."
$ASADMIN start-domain domain1

# asadmin start-domain is synchronous; returns only when the domain is ready
log "GlassFish is ready ✓"
sleep 5  # extra wait to ensure the admin REST interface is fully initialized

# ─────────────────────────────────────────────────────────────
# 2. Enable Secure Admin (allows remote access to the Admin Console)
# ─────────────────────────────────────────────────────────────
log "Enabling Secure Admin..."
PWFILE_CHANGE=$(mktemp)
printf 'AS_ADMIN_PASSWORD=\nAS_ADMIN_NEWPASSWORD=admin123\n' > "$PWFILE_CHANGE"
$GLASSFISH_HOME/bin/asadmin --user admin --passwordfile "$PWFILE_CHANGE" \
    change-admin-password && log "Admin password set ✓" || log "Warning: password change failed (may already be set)"
rm -f "$PWFILE_CHANGE"

# Update passwordfile to use the new password
echo "AS_ADMIN_PASSWORD=admin123" > "$PWFILE"
ASADMIN="$GLASSFISH_HOME/bin/asadmin --user admin --passwordfile $PWFILE"

$ASADMIN enable-secure-admin && log "Secure Admin enabled ✓" || log "Warning: enable-secure-admin failed"

log "Restarting GlassFish to activate Secure Admin..."
$ASADMIN stop-domain domain1
$ASADMIN start-domain domain1
sleep 5
log "GlassFish restart complete ✓"

# ─────────────────────────────────────────────────────────────
# 3. Configure MySQL JDBC datasource
# ─────────────────────────────────────────────────────────────
log "Configuring MySQL JDBC datasource..."

# Clean up any existing config (ignore errors if not present)
$ASADMIN delete-jdbc-resource jdbc/archemyapp 2>/dev/null || true
$ASADMIN delete-jdbc-connection-pool ArchemyPool 2>/dev/null || true

# Create connection pool
$ASADMIN create-jdbc-connection-pool \
    --datasourceclassname com.mysql.jdbc.jdbc2.optional.MysqlDataSource \
    --restype javax.sql.DataSource \
    --property "User=${MYSQL_USER}:Password=${MYSQL_PASSWORD}:URL=jdbc\:mysql\://${MYSQL_HOST}\:${MYSQL_PORT}/${MYSQL_DB}:useSSL=false:allowPublicKeyRetrieval=true" \
    ArchemyPool && log "Connection pool ArchemyPool created ✓" || log "Warning: connection pool creation failed"

# Create JNDI resource (application looks up jdbc/archemyapp)
$ASADMIN create-jdbc-resource \
    --connectionpoolid ArchemyPool \
    jdbc/archemyapp && log "JNDI resource jdbc/archemyapp created ✓" || log "Warning: JNDI resource creation failed"

# Test database connectivity
$ASADMIN ping-connection-pool ArchemyPool && \
    log "Database connection test: OK ✓" || \
    log "Warning: database connection test failed (MySQL may not be ready yet)"

# ─────────────────────────────────────────────────────────────
# 4. Deploy ArchNav application
# ─────────────────────────────────────────────────────────────
log "Waiting for autodeploy to complete..."
sleep 20

# Check whether autodeploy already picked up the WAR
$ASADMIN list-applications 2>/dev/null | grep -q archemy && {
    log "Application deployed via autodeploy ✓"
} || {
    log "Deploying archemy.war manually..."
    $ASADMIN deploy \
        --contextroot archemy \
        --name archemy \
        $GLASSFISH_HOME/glassfish/domains/domain1/autodeploy/archemy.war && \
        log "Manual deployment successful ✓" || log "Warning: deployment failed, check logs"
}

log "========================================"
log "ArchNav is running!"
log "Application: http://localhost:9999/archemy/faces/login.jspx"
log "Admin Console: https://localhost:4848  (accept self-signed certificate)"
log "Console credentials: admin / admin123"
log "Application credentials: admin / password"
log "========================================"

# ─────────────────────────────────────────────────────────────
# 5. Keep container alive by tailing the GlassFish log
# ─────────────────────────────────────────────────────────────
rm -f "$PWFILE"
tail -f "$LOG" 2>/dev/null || while true; do sleep 30; done
