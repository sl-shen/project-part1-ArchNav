#!/bin/bash
set -e

FORTRESS_DIR="/opt/fortress-core-2.0.3"
SCHEMA_LDIF="$FORTRESS_DIR/ldap/schema/apacheds-fortress.ldif"
INIT_LDIF="$FORTRESS_DIR/src/test/resources/init-ldap.ldif"
TESTDATA_LDIF="$FORTRESS_DIR/src/test/resources/test-data.ldif"
INIT_MARKER="/var/lib/apacheds-2.0.0.AM25/default/.fortress_initialized"

LDAP_HOST="127.0.0.1"
LDAP_PORT="10389"
ADMIN_DN="uid=admin,ou=system"
ADMIN_PW="secret"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

ldap_add() {
    ldapadd -c -h "$LDAP_HOST" -p "$LDAP_PORT" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" \
        -f "$1" 2>&1 | grep -v "^adding" | grep -v "^$" || true
}

# ─────────────────────────────────────────────────────────────
# 1. Start ApacheDS
# ─────────────────────────────────────────────────────────────
log "Starting ApacheDS 2.0.0.AM25..."

APACHEDS_JAR=$(find /opt/apacheds-2.0.0.AM25 -name "apacheds-service*.jar" 2>/dev/null | head -1)
if [ -z "$APACHEDS_JAR" ]; then
    log "ERROR: apacheds-service*.jar not found"
    ls /opt/apacheds-2.0.0.AM25/lib/ && exit 1
fi

java -jar "$APACHEDS_JAR" /var/lib/apacheds-2.0.0.AM25/default &
APACHEDS_PID=$!

# ─────────────────────────────────────────────────────────────
# 2. Wait for LDAP port to become available
# ─────────────────────────────────────────────────────────────
log "Waiting for LDAP port $LDAP_PORT..."
for i in $(seq 1 100); do
    nc -z "$LDAP_HOST" "$LDAP_PORT" 2>/dev/null && log "ApacheDS is ready ✓" && break
    [ "$i" -eq 100 ] && log "ERROR: ApacheDS did not start within 300s" && exit 1
    sleep 3
done

# ─────────────────────────────────────────────────────────────
# 3. First-time initialization (runs only once)
# ─────────────────────────────────────────────────────────────
if [ ! -f "$INIT_MARKER" ]; then
    log "First run: starting Fortress LDAP initialization..."

    # Step 3a: Load Fortress schema into ApacheDS
    log "3a. Loading Fortress schema: apacheds-fortress.ldif"
    ldap_add "$SCHEMA_LDIF"
    log "Schema loaded, waiting for ApacheDS to process..."
    sleep 5

    # Step 3b: Create Fortress DIT structure (People, RBAC, Roles OUs)
    log "3b. Creating DIT structure: init-ldap.ldif"
    ldap_add "$INIT_LDIF"

    # Step 3c: Load test users and roles
    log "3c. Loading test data: test-data.ldif"
    ldap_add "$TESTDATA_LDIF"

    # Step 3d: Create ArchNav-specific roles
    # Note: ftRoleNm does not exist in Fortress 2.0.3 schema; use cn and ftId only
    log "3d. Creating ArchNav roles (Admin / NormalUser)"
    ldapadd -c -h "$LDAP_HOST" -p "$LDAP_PORT" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" 2>&1 << 'LDIF' | grep -v "^adding" || true
dn: cn=Admin,ou=Roles,ou=RBAC,dc=example,dc=com
objectClass: top
objectClass: ftRls
cn: Admin
ftId: Admin
ftRoleName: Admin
description: ArchNav Administrator Role

dn: cn=NormalUser,ou=Roles,ou=RBAC,dc=example,dc=com
objectClass: top
objectClass: ftRls
cn: NormalUser
ftId: NormalUser
ftRoleName: NormalUser
description: ArchNav Normal User Role
LDIF

    # Step 3e: Create ArchNav test users
    log "3e. Creating ArchNav test users"
    ldapadd -c -h "$LDAP_HOST" -p "$LDAP_PORT" \
        -D "$ADMIN_DN" -w "$ADMIN_PW" 2>&1 << 'LDIF' | grep -v "^adding" || true
dn: uid=admin,ou=People,dc=example,dc=com
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
objectClass: ftUserAttrs
uid: admin
cn: Admin User
sn: Admin
userPassword: password
ftId: adminUser001
ftRC: Admin$20260101$none$none$none
ftRC: NormalUser$20260101$none$none$none
ftRA: Admin
ftRA: NormalUser

dn: uid=user1,ou=People,dc=example,dc=com
objectClass: inetOrgPerson
objectClass: organizationalPerson
objectClass: person
objectClass: ftUserAttrs
uid: user1
cn: Normal User
sn: User
userPassword: password
ftId: normalUser001
ftRC: NormalUser$20260101$none$none$none
ftRA: NormalUser
LDIF

    touch "$INIT_MARKER"
    log "Fortress LDAP initialization complete ✓"
else
    log "LDAP already initialized, skipping (delete $INIT_MARKER to force re-initialization)"
fi

# ─────────────────────────────────────────────────────────────
# 4. Verify DIT structure
# ─────────────────────────────────────────────────────────────
log "Verifying DIT structure..."
ldapsearch -h "$LDAP_HOST" -p "$LDAP_PORT" \
    -D "$ADMIN_DN" -w "$ADMIN_PW" \
    -b "dc=example,dc=com" "(objectClass=*)" dn 2>&1 | grep "^dn:" | head -20

log "========================================"
log "ApacheDS ready | Port: $LDAP_PORT"
log "Test account: uid=admin  password: password (Admin role)"
log "Test account: uid=user1  password: password (NormalUser role)"
log "========================================"

# ─────────────────────────────────────────────────────────────
# 5. Wait on ApacheDS process (keeps container alive)
# ─────────────────────────────────────────────────────────────
wait "$APACHEDS_PID"
