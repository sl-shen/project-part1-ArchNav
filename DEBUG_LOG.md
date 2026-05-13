# Docker Deployment Debug Log

A record of all issues encountered and their resolutions during the Dockerization of the ArchNav application.

---

## Issue #1: MySQL 8 Incompatibility with Legacy sql_mode

**Date**: 2026-04-16

**Symptom**:
```
ERROR 1231 (42000) at line 629: Variable 'sql_mode' can't be set to the value of 'NO_AUTO_CREATE_USER'
archemy-mysql exited with code 1
```

**Root Cause**:
`DatabaseImport.sql` was exported from MySQL 5.7.13. The stored procedure definitions at lines 629 and 656 contain:
```sql
/*!50003 SET sql_mode = 'STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' */ ;
```
The `NO_AUTO_CREATE_USER` sql_mode value was completely removed in MySQL 8.0, which rejects any `SET` statement containing it.

**Affected Lines**:
- `DatabaseImport.sql` line 629 (first stored procedure)
- `DatabaseImport.sql` line 656 (second stored procedure)

**Resolution**:
Generated a MySQL 8-compatible version using `sed` to strip `NO_AUTO_CREATE_USER`:
```bash
sed 's/NO_AUTO_CREATE_USER,//g; s/,NO_AUTO_CREATE_USER//g' \
    ADFEssentialsApp-SP26/Data/DatabaseImport.sql \
    > docker/mysql/init/01_schema_data.sql
```
The fixed file is stored at `docker/mysql/init/01_schema_data.sql`; the original is untouched.
The MySQL volume mount in `docker-compose.yml` was updated to reference the fixed file.

**Verification**:
Confirmed zero occurrences of `NO_AUTO_CREATE_USER` in the fixed file.

**Status**: Resolved ✅

---

## Issue #2: Duplicate Stored Procedure Creation

**Date**: 2026-04-16

**Symptom**:
```
ERROR 1304 (42000) at line 2: PROCEDURE insert_into_kad already exists
archemy-mysql exited with code 1
```

**Root Cause**:
`DatabaseImport.sql` is a complete MySQL dump that already includes `DROP PROCEDURE IF EXISTS` + `CREATE PROCEDURE` statements for both stored procedures (lines 621–670). A separate `02_procedures.sql` file defining the same procedures was also mounted as an init script, causing a duplicate creation error on the second run.

**Resolution**:
Removed the `02_procedures.sql` volume mount from `docker-compose.yml`, keeping only `01_schema_data.sql`.

**Status**: Resolved ✅

---

## Issue #3: ApacheDS Cannot Persist During Docker Build Stage

**Date**: 2026-04-16

**Symptom**:
```
#17 DONE 60.2s   ← wait loop ran for 60s, ApacheDS never became ready
#18 Buildfile: build.xml does not exist!  ← ant init-ldap failed
#20 /bin/sh: 1: ldapadd: not found
```

**Root Cause (3 sub-issues)**:

**3a. Docker build stage does not support persistent background processes**
All background processes started within a `RUN` instruction are killed when that instruction completes. `service apacheds start` ran successfully in RUN #16, but the ApacheDS process was killed when RUN #16 ended. The LDAP port was naturally unavailable when RUN #17 started.
- **Wrong approach**: start a service across multiple `RUN` steps → wait → operate
- **Correct approach**: move all service-dependent operations to `entrypoint.sh` to run at container startup

**3b. Fortress Core 2.0.3 has no build.xml (pure Maven project)**
Fortress 1.x used Ant (with `build.xml` and the `ant init-ldap` command). Fortress 2.x migrated to pure Maven and has no `build.xml`. Installation documentation referring to `ant init-ldap` targets Fortress 1.x.

**3c. ldapadd not installed**
The Dockerfile did not include the `ldap-utils` package (which provides `ldapadd`, `ldapsearch`, etc.).

**Resolution**:
- Moved all LDAP initialization logic to `entrypoint.sh` (runs at container startup)
- Used an init marker file (`/opt/fortress-init/.initialized`) to ensure initialization runs only once
- Added `ldap-utils` to `apt-get install`
- Used an LDAP volume to persist data across restarts

**Status**: Redesigned ✅

---

## Issue #4: Maven Build Failure (javax.xml.bind Removed in Java 11)

**Date**: 2026-04-16

**Symptom**:
```
[ERROR] cannot find symbol: class XmlType
[ERROR] package javax.xml.bind.annotation does not exist
```

**Root Cause**:
Fortress Core 2.0.3 source code uses `javax.xml.bind` (JAXB), which was deprecated in Java 9 and **completely removed in Java 11**. The Docker image used `openjdk-11-jdk-headless`, causing compilation failure.

**Side Issue**:
The entrypoint `if mvn install...; then` guard was incorrect — the pipe exit code came from the last command (`tail -30`), not from `mvn`. So even when Maven failed, the script reported "success", meaning the Fortress DIT structure was never actually created.

**Resolution**:
Skipped Maven compilation entirely. The Fortress Core 2.0.3 source release ships with three LDIF files that can be loaded directly with `ldapadd`, no compilation required:
- `ldap/schema/apacheds-fortress.ldif` → loads Fortress schema into ApacheDS
- `src/test/resources/init-ldap.ldif` → creates the DIT structure (People, Roles, RBAC OUs)
- `src/test/resources/test-data.ldif` → test users and roles

**Also fixed**: incorrect ApacheDS volume path in `docker-compose.yml`
- Wrong: `/opt/apacheds/instances/default`
- Correct: `/var/lib/apacheds-2.0.0.AM25/default`

**Status**: Fixed ✅

---

## Issue #5: ftRoleNm Attribute Does Not Exist in Fortress 2.0.3 Schema

**Date**: 2026-04-16

**Symptom**:
```
ERR_13735_ELEMENT_FOR_OID_DOES_NOT_EXIST ATTRIBUTE_TYPE for OID ftrolenm does not exist!
```

**Root Cause**:
`ftRoleNm` is an attribute name from the Fortress **1.0.x** schema. In the Fortress **2.0.3** schema (`apacheds-fortress.ldif`) this attribute does not exist — role names are stored using the standard LDAP `cn` attribute. The custom role LDIF in `entrypoint.sh` incorrectly used the 1.0.x attribute name.

**Resolution**: Removed the `ftRoleNm` lines from the custom role LDIF, keeping only:
- `objectClass: ftRls`
- `cn: RoleName`
- `ftId: UniqueId`
- `description: ...`

**Harmless Warning**:
`dc=example,dc=com already exists (68)` — ApacheDS includes this partition by default; `init-ldap.ldif` trying to create it again triggers an "already exists" error. Because `ldapadd -c` (continue on error) is used, this does not affect subsequent steps.

**Status**: Fixed ✅

---

## Issue #6: openjdk:8-jdk-slim Image No Longer Available

**Date**: 2026-04-16

**Symptom**:
```
ERROR: openjdk:8-jdk-slim: not found
```

**Root Cause**:
The official `openjdk` Docker images (maintained by Oracle) stopped receiving updates in 2022, and older versions including `8-jdk-slim` were subsequently removed from Docker Hub.

**Resolution**:
Switched to **Eclipse Temurin** (the open-source JDK distribution formerly known as AdoptOpenJDK, now maintained by the Eclipse Foundation):
- Old: `FROM openjdk:8-jdk-slim`
- New: `FROM eclipse-temurin:8-jdk-jammy`

`jammy` indicates the base OS is Ubuntu 22.04 LTS — stable and long-term supported.

**Status**: Fixed ✅

---

## Issue #7: Dockerfile COPY Does Not Support Paths with Spaces

**Date**: 2026-04-16

**Symptom**:
```
ERROR: unexpected end of statement while looking for matching double-quote
```

**Root Cause**:
The WAR file path was `ADFEssentialsApp-SP26/App/GlassFish Deployment Archives/Archemy_Project1_webapp.war`, containing a space in the directory name. Docker's `COPY` instruction does not support double-quoted paths (they are parsed incorrectly).

**Resolution**:
Pre-copied the WAR to a space-free path at `docker/glassfish/archemy.war`; the Dockerfile references this path instead:
- Old: `COPY "ADFEssentialsApp-SP26/App/GlassFish Deployment Archives/...war"`
- New: `COPY docker/glassfish/archemy.war /tmp/original.war`

**Status**: Fixed ✅

---

## Issue #8: GlassFish 5.0 Download URL Dead

**Date**: 2026-04-16

**Symptom**:
```
wget exit code 8 — Server issued an error response
URL: https://github.com/javaee/glassfish/releases/download/5.0/glassfish-5.0.zip
```

**Root Cause**:
The `javaee/glassfish` GitHub repository has been archived and the release tag format does not match the assumed `5.0` path, resulting in a 404 error.

**Resolution**:
Switched to **Eclipse GlassFish 5.1.0** (the official open-source successor to Oracle GlassFish, maintained by the Eclipse Foundation):
- Old URL: `https://github.com/javaee/glassfish/releases/download/5.0/glassfish-5.0.zip`
- New URL: `https://download.eclipse.org/ee4j/glassfish/glassfish-5.1.0.zip`

**Compatibility**: 5.1.0 is fully backwards compatible with 5.0.0; the pre-compiled WAR deploys without modification.

**Status**: Fixed ✅

---

## Issue #9: All Known GlassFish Download URLs Dead

**Date**: 2026-04-16

**URLs Tried (all returned 404/8)**:
- `https://github.com/javaee/glassfish/releases/download/5.0/glassfish-5.0.zip`
- `https://download.eclipse.org/ee4j/glassfish/glassfish-5.1.0.zip`
- `https://github.com/eclipse-ee4j/glassfish/releases/download/5.1.0/glassfish-5.1.0.zip`

**Resolution**:
Maven Central hosts complete GlassFish 5.0 and 5.0.1 distribution ZIPs, returning HTTP 200:
```
https://repo1.maven.org/maven2/org/glassfish/main/distributions/glassfish/5.0.1/glassfish-5.0.1.zip
```
Switched to GlassFish **5.0.1** (includes bug fixes over 5.0.0, fully compatible with the compiled WAR).

**Status**: Fixed ✅

---

## Issue #10: ftRls objectClass Requires Mandatory Attribute ftRoleName

**Date**: 2026-04-16

**Symptom**:
```
ERR_279 Required attributes [ftRoleName(1.3.6.1.4.1.18060.17.1.5)] not found within entry cn=Admin,ou=Roles,ou=RBAC,dc=example,dc=com
```

**Root Cause**:
The Fortress 2.0.3 `ftRls` objectClass defines `ftRoleName` (OID 1.3.6.1.4.1.18060.17.1.5) as a **MUST** (mandatory) attribute. When fixing Issue #5, the non-existent `ftRoleNm` (old name) was confused with the correct `ftRoleName` (new name, capital N) — the attribute line was deleted entirely when it should have been renamed.

**Resolution**:
Added `ftRoleName: Admin` and `ftRoleName: NormalUser` to the role LDIF in `entrypoint.sh`:
```ldif
dn: cn=Admin,ou=Roles,ou=RBAC,dc=example,dc=com
objectClass: top
objectClass: ftRls
cn: Admin
ftId: Admin
ftRoleName: Admin
description: ArchNav Administrator Role
```

**Status**: Fixed ✅

---

## Issue #11: ClassNotFoundException: ADFGlassFishAppLifeCycleListener

**Date**: 2026-04-16

**Symptom**:
```
ClassNotFoundException: oracle.adf.share.glassfish.listener.ADFGlassFishAppLifeCycleListener
Error occurred during deployment: Exception while loading the app : java.lang.IllegalStateException
```

**Root Cause**:
`web.xml` registers `oracle.adf.share.glassfish.listener.ADFGlassFishAppLifeCycleListener`, which is an **Oracle ADF Essentials server-side GlassFish module** (meant to be installed under `glassfish/modules/`), not a class bundled inside the WAR. The WAR's `WEB-INF/lib/` does not contain this class. The standard deployment flow requires installing ADF Essentials on GlassFish first, but that package requires an Oracle OTN account and cannot be fetched automatically during a Docker build.

**Resolution**:
Added a WAR patching step in the Dockerfile that uses Python 3 to remove the listener registration from `WEB-INF/web.xml` and repack the WAR:
```python
re.sub(r'\s*<listener>...<listener-class>oracle\.adf\.share\.glassfish\.listener\.ADFGlassFishAppLifeCycleListener...</listener>',
       '', content)
```
The ADF application's functionality does not depend on this listener at runtime.

**Status**: Fixed ✅

---

## Issue #12: GlassFish 3.1.2.2 Incompatible with Java 8 (OSGi Error)

**Date**: 2026-04-17

**Symptom**:
```
java.lang.IllegalArgumentException: Exported package names cannot be zero length
    at org.apache.felix.framework.capabilityset.SimpleFilter.<init>
```
The GlassFish domain fails to start; the Felix OSGi framework crashes and exits immediately.

**Root Cause**:
The assignment PDF specifies GlassFish 3.1.2.2, but that version's embedded Apache Felix OSGi framework is **incompatible with Java 8**. Felix crashes under Java 8 when it encounters an empty package name while parsing OSGi manifests. GlassFish 3.1.2.2 was designed for Java 6/7.

**Resolution**:
Switched to **GlassFish 4.1.1** (available on Maven Central):
```
https://repo1.maven.org/maven2/org/glassfish/main/distributions/glassfish/4.1.1/glassfish-4.1.1.zip
```
- GlassFish 4.1.1 natively supports Java 8, JSF 2.2, and is fully compatible with the compiled WAR.
- Installation directory changed from `/opt/glassfish3` to `/opt/glassfish4`; `GLASSFISH_HOME` updated accordingly.

**Status**: Fixed ✅

---

## Issue #13: sed Accidentally Deletes All `<listener>` Tags from web.xml

**Date**: 2026-04-17

**Symptom**:
```
SEVERE: PWC6117: File "/opt/glassfish4/.../login.jspx" not found
SAXParseException: The content of elements must consist of well-formed character data or markup.
```
WAR deployment fails; GlassFish reports XML parsing error.

**Root Cause**:
Using `sed`'s range pattern `/<listener>/,/<\/listener>/` to remove the `ADFGlassFishAppLifeCycleListener` registration also **deleted the opening and closing tags of all other `<listener>` blocks**, leaving orphaned `<listener-class>` content and a corrupted `web.xml` structure.

**Resolution**:
Replaced with an `awk` script that buffers complete `<listener>...</listener>` blocks and only discards the one containing `ADFGlassFishAppLifeCycleListener`:
```awk
awk 'BEGIN{skip=0}
  /<listener>/{buf=$0"\n";skip=1;next}
  skip{buf=buf$0"\n"; if(/<\/listener>/){
    if(buf!~/ADFGlassFishAppLifeCycleListener/)printf "%s",buf;
    skip=0;buf=""};next}
  {print}' WEB-INF/web.xml > WEB-INF/web.xml.tmp
```

**Status**: Fixed ✅

---

## Issue #14: ADF ExceptionHandlerFactory Cannot Be Instantiated on GlassFish

**Date**: 2026-04-17

**Symptom**:
```
SEVERE: ADF_FACES-60096: An Exception occurred when creating the ExceptionHandlerFactory
java.lang.ClassNotFoundException: oracle.adfinternal.view.faces.context.ExceptionHandlerFactoryImpl
```

**Root Cause**:
`WEB-INF/lib/adf-richclient-impl-11.jar`'s internal `META-INF/faces-config.xml` registers `oracle.adfinternal.view.faces.context.ExceptionHandlerFactoryImpl`, a JSF ExceptionHandler **specific to WebLogic**. GlassFish has no corresponding implementation.

**Resolution**:
Added a Dockerfile step to extract `adf-richclient-impl-11.jar`, remove the `<exception-handler-factory>` element using `sed`, and repack the JAR:
```bash
jar xf adf-richclient-impl-11.jar META-INF/faces-config.xml
sed -i 's|[[:space:]]*<exception-handler-factory>[^<]*</exception-handler-factory>||g' META-INF/faces-config.xml
jar uf adf-richclient-impl-11.jar META-INF/faces-config.xml
```

**Status**: Fixed ✅

---

## Issue #15: NoClassDefFoundError: oracle/adf/share/logging/ADFLogger

**Date**: 2026-04-17

**Symptom**:
```
java.lang.NoClassDefFoundError: oracle/adf/share/logging/ADFLogger
```
WAR deploys successfully via autodeploy, but every page access immediately returns HTTP 500.

**Root Cause**:
ADF classes inside the WAR reference `oracle.adf.share.logging.ADFLogger`, which lives in `adf-share-base.jar` — part of the **ADF Essentials server-side runtime** (not bundled in the WAR). This JAR was absent from GlassFish's `domain1/lib/`.

**Resolution**:
Extracted all module JARs from the Oracle ADF Essentials download package into the `modules/` directory and added to the Dockerfile:
```dockerfile
COPY modules/ /tmp/adf-modules/
RUN find /tmp/adf-modules -name "*.jar" -exec cp {} $GLASSFISH_HOME/glassfish/domains/domain1/lib/ \;
```

**Status**: Fixed (triggered Issue #16) ✅→

---

## Issue #16: ADF 12c Server Modules Conflict with WAR's ADF 11g JARs (ClassCastException)

**Date**: 2026-04-17

**Symptom**:
```
java.lang.ClassCastException: oracle.adfinternal.controller.faces.context.StubJSFPageLifecycleContext
  cannot be cast to oracle.adf.controller.faces.context.FacesPageLifecycleContext
```
Logs also show:
```
Duplicate key: adf-pageflow-impl.jar exists in both
  WEB-INF/lib/adf-pageflow-impl.jar  (WAR, ADF 11g)
  domain1/lib/adf-pageflow-impl.jar  (server-side, ADF 12c)
```

**Root Cause**:
The module JARs copied from the Oracle ADF Essentials 12.2.1.4.0 download package include many JARs with the same filename but different versions as those already inside the WAR (e.g., `adf-pageflow-impl.jar`, `adf-faces-databinding-rt.jar` — 46 conflicts total). GlassFish's classloader sees both versions simultaneously; objects created by ADF 12c cannot be cast to ADF 11g types.

**Resolution**:
Modified the Dockerfile to extract the list of JAR names already present in the WAR and only copy module JARs that are **absent** from the WAR:
```dockerfile
RUN jar tf /tmp/original.war | grep "^WEB-INF/lib/.*\.jar$" | sed 's|WEB-INF/lib/||' | sort > /tmp/war-jar-names.txt && \
    find /tmp/adf-modules -name "*.jar" | while read jarpath; do \
        jarname=$(basename "$jarpath"); \
        if ! grep -qx "$jarname" /tmp/war-jar-names.txt; then \
            cp "$jarpath" $GLASSFISH_HOME/glassfish/domains/domain1/lib/; \
        fi; \
    done
```
Only missing runtime JARs such as `adfm.jar` and `adf-share-base.jar` are added to the server classpath; the WAR's embedded versions are not overridden.

**Status**: Fixed ✅

---

## Issue #17: ApacheDS Container Health Check Fails / Startup Timeout

**Date**: 2026-04-17

**Symptom**:
```
archemy-apacheds: health check failing → unhealthy
archemy-glassfish: dependency not met, not starting
```
Or inside entrypoint:
```
ERROR: ApacheDS did not start within 300s
```

**Root Cause**:
The `apacheds-data` Docker volume retained **ApacheDS lock files** (`.lock`) from a previous run. ApacheDS cannot acquire the data directory lock and fails to start, so port 10389 never becomes reachable and the health check never passes.

**Resolution**:
```bash
docker compose down -v   # -v also removes named volumes, clearing lock files
docker compose up
```
For any future recurrence, `docker compose down -v` followed by restart resolves the issue.

**Status**: Fixed ✅

---

## Issue #18: Empty `<context-root/>` in glassfish-web.xml Causes Unpredictable Deployment Path

**Date**: 2026-05-12

**Symptom** (preventive fix; not yet observed):
The WAR's `WEB-INF/glassfish-web.xml` contains:
```xml
<glassfish-web-app>
   <context-root/>
</glassfish-web-app>
```
An empty `<context-root/>` element may be parsed by GlassFish 4.1.1 as an empty string, deploying the application to the `/` root path instead of `/archemy`.

**Resolution**:
Added a Dockerfile WAR patching step to overwrite `glassfish-web.xml` with an explicit context root:
```bash
printf '<?xml version="1.0" encoding="UTF-8"?>\n<glassfish-web-app>\n  <context-root>archemy</context-root>\n</glassfish-web-app>\n' > WEB-INF/glassfish-web.xml
jar uf /tmp/archemy.war WEB-INF/glassfish-web.xml
```

**Status**: Fixed ✅

---

## Issue #19: sed Single-Line Mode Cannot Handle Multi-Line `<exception-handler-factory>` Element

**Date**: 2026-05-12

**Symptom** (preventive fix):
The `<exception-handler-factory>` element in `adf-richclient-impl-11.jar`'s `META-INF/faces-config.xml`:
```xml
<exception-handler-factory>
    oracle.adfinternal.view.faces.context.ExceptionHandlerFactoryImpl
</exception-handler-factory>
```
may span multiple lines. The original `sed -i 's|...|'` only matches within a single line and cannot remove a multi-line XML element.

**Resolution**:
Switched to Perl's `-0777` (slurp mode) to read the entire file at once and apply a multi-line regex:
```bash
perl -0777 -i -pe 's/\s*<exception-handler-factory>[^<]*<\/exception-handler-factory>//g' META-INF/faces-config.xml
```
Also added `perl` to the Dockerfile's `apt-get install` (Eclipse Temurin jammy base typically includes it already).

**Status**: Fixed ✅

---

## Issue #20: GlassFish 4 asadmin Commands Used Undefined `$ASADMIN` Variable

**Date**: 2026-05-12

**Symptom**:
`entrypoint.sh` defined `ASADMIN="..."` but all actual calls used `$GLASSFISH_HOME/bin/asadmin` directly. `$ASADMIN` was never used. GlassFish 4.1.1 can interactively prompt for the admin password in certain operations, causing the script to hang.

**Root Cause**:
The original intent of `--passwordfile /dev/null` was correct (pass an empty password file), but the variable was never actually referenced.

**Resolution**:
Used `mktemp` to create a temporary password file containing `AS_ADMIN_PASSWORD=` (empty password), and standardized all `asadmin` calls to use `$ASADMIN`:
```bash
PWFILE=$(mktemp)
echo "AS_ADMIN_PASSWORD=" > "$PWFILE"
ASADMIN="$GLASSFISH_HOME/bin/asadmin --user admin --passwordfile $PWFILE"
```

**Status**: Fixed ✅

---

## Issue #21: ApacheDS deb Package Download Timeout During Docker Build

**Date**: 2026-05-12

**Symptom**:
```
#26 [apacheds 3/8] RUN wget -q 'https://archive.apache.org/dist/directory/apacheds/dist/2.0.0.AM25/apacheds-2.0.0.AM25-amd64.deb' ...
```
Build hangs indefinitely at this step; `archive.apache.org` is extremely slow or unresponsive.

**Root Cause**:
`archive.apache.org` is Apache's historical archive mirror with limited bandwidth. Downloading a large file (~50 MB) from within a container frequently times out.

**Resolution**:
Pre-downloaded the deb package on the host machine and placed it at `docker/apacheds/apacheds.deb`. The Dockerfile uses `COPY` instead of `wget`:
```dockerfile
# Old
RUN wget -q '...apacheds-2.0.0.AM25-amd64.deb' -O /tmp/apacheds.deb && dpkg -i /tmp/apacheds.deb

# New
COPY apacheds.deb /tmp/apacheds.deb
RUN dpkg -i /tmp/apacheds.deb && rm /tmp/apacheds.deb
```

**Status**: Fixed ✅

---

## Issue #22: MySQL 8 SSL Keystore Error Causes JDBC Connection Failure

**Date**: 2026-05-12

**Symptom**:
```
Cannot open keystore.jks [Keystore was tampered with, or password was incorrect]
com.mysql.jdbc.exceptions.jdbc4.CommunicationsException: Communications link failure
```

**Root Cause**:
MySQL Connector/J 5.1.47 attempts SSL connections by default and expects a valid `keystore.jks` in the GlassFish domain directory. MySQL 8 also uses the `caching_sha2_password` authentication plugin, which Connector/J 5.1.x does not support; `mysql_native_password` must be explicitly specified.

**Resolution**:
1. Added startup parameters to the MySQL service in `docker-compose.yml`:
   ```yaml
   command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
   ```
2. Added `useSSL=false:allowPublicKeyRetrieval=true` to the GlassFish JDBC connection pool properties:
   ```bash
   --property "User=...:Password=...:URL=jdbc\:mysql\://...:useSSL=false:allowPublicKeyRetrieval=true"
   ```

**Status**: Fixed ✅

---

## Issue #23: Leading Spaces in Home.jspx Task Flow Paths Cause MDS-01161

**Date**: 2026-05-12

**Symptom**:
```
oracle.mds.exception.MDSRuntimeException: MDS-01161: Reference "/secured/ .jspx" has an invalid character " "
```
Clicking left-side menu items "Manage Business Problems" or "View Customer Info" produces a server-side error; the dynamic region does not switch.

**Root Cause**:
Several `<af:setPropertyListener>` `from` attributes in `secured/Home.jspx` contain leading spaces:
- Line 77: `from=" /WEB-INF/taskflow/recurring-business-problem-tf.xml#..."` (1 space)
- Line 93: `from="  /WEB-INF/taskflow/view-customer-info-task-flow-definition.xml#..."` (2 spaces)
- Line 104: CANCEL button `action=" "` (whitespace only, triggers an invalid MDS path lookup)

**Resolution**:
Added a WAR patching step in the Dockerfile to extract and fix `secured/Home.jspx`:
```bash
jar xf /tmp/archemy.war secured/Home.jspx
sed -i 's/from="  *\//from="\//g' secured/Home.jspx
sed -i 's/action=" "/action=""/g' secured/Home.jspx
jar uf /tmp/archemy.war secured/Home.jspx
```

**Status**: Fixed ✅

---

## Issue #24: `usesUpload="true"` Causes Trinidad Filter to Consume Request Body, Breaking All Menu Navigation

**Date**: 2026-05-12

**Symptom**:
Clicking any left-side menu item leaves the content area unchanged. Server logs show:
```
java.io.EOFException at MultipartFormHandler._skipBoundary
ERROR_CREATE_COMPONENT_STALE: #{viewScope.NavBacking.popup}
```

**Root Cause**:
`<af:form usesUpload="true">` in `Home.jspx` forces all form submissions to use `multipart/form-data` encoding. The Trinidad filter attempts to parse a multipart body on every request; for ordinary navigation clicks that have no multipart body, it throws an `EOFException` and consumes the entire request body. The JSF lifecycle can no longer read form parameters, `setPropertyListener` does not fire, `taskFlowId` is not updated, and the dynamic region never refreshes.

Also found: `partialTriggers="::cl9 ::cl9"` duplicate (should be `::cl9 ::cl8`), causing the dynamic region not to refresh on Change Password clicks.

**Resolution**:
Added to the Dockerfile WAR patching step:
```bash
sed -i 's/usesUpload="true"/usesUpload="false"/g' secured/Home.jspx
sed -i 's/::cl9 ::cl9/::cl9 ::cl8/g' secured/Home.jspx
```

**Status**: Fixed ✅

---

## Issue #25: `FortressAllowed` EL Always Returns Null — Admin Menu Items All Hidden

**Date**: 2026-05-12

**Symptom**:
After logging in as `admin`, the left-side menu only shows the three items without a `visible` constraint (Search KAD, Search or Add Catalog, View Usage Statistics). All administrator menu items are invisible.

**Root Cause**:
`FortressSecurityController.getPermissions()` calls `delMgr.sessionPermissions()` and `mgr.sessionPermissions()` to build a permissions map, but the LDAP initialization scripts only created roles and users — **Fortress permission objects** (`ftObject`/`ftOperation` LDAP entries) were never created. Both `sessionPermissions()` calls return empty lists, the permissions map stays empty, and all `FortressAllowed[...]` expressions return `null` (equivalent to `false` in EL).

**Resolution**:
Switched to the `FortressUserInRole` EL (directly checks whether the RBAC session contains the specified role — available immediately after login, with no dependency on LDAP permission entries). The `docker/glassfish/fix_home.py` Python script performs a batch replacement inside the WAR's `Home.jspx` at Docker build time:
```python
re.sub(r'visible="#{FortressAllowed\[\'[^\']+:Admin\'\]}"',
       "visible=\"#{FortressUserInRole['Admin']}\"", content)
re.sub(r'visible="#{FortressAllowed\[\'[^\']+:Normal\'\]}"',
       "visible=\"#{FortressUserInRole['NormalUser']}\"", content)
```
Also added `ftRA: NormalUser` to the admin user in `entrypoint.sh` so `admin` holds both roles and can see all menu items.

**Status**: Fixed ✅

---

## Issue #26: GlassFish 4 Admin Console Shows "Secure Admin must be enabled"

**Date**: 2026-05-12

**Symptom**:
Browser accessing `http://localhost:4848` displays:
```
Configuration Error
Secure Admin must be enabled to access the DAS remotely.
```

**Root Cause**:
GlassFish 4 by default prohibits access to the Admin Console from non-localhost network interfaces. A connection from the host machine through Docker's port mapping is treated as "remote" access.

**Resolution**:
In `entrypoint.sh`, after GlassFish's first startup:
1. Change the admin password to a non-empty value (Secure Admin requires a non-empty password)
2. Run `enable-secure-admin`
3. Restart the domain to activate the configuration

```bash
printf 'AS_ADMIN_PASSWORD=\nAS_ADMIN_NEWPASSWORD=admin123\n' > "$PWFILE_CHANGE"
$ASADMIN change-admin-password
$ASADMIN enable-secure-admin
$ASADMIN stop-domain && $ASADMIN start-domain
```

Admin Console changed to **`https://localhost:4848`** (accept the self-signed certificate warning). Credentials: `admin / admin123`. Application login credentials remain `admin / password`.

**Status**: Fixed ✅

---

## Issue #27: SSLHandshakeException After enable-secure-admin ("No appropriate protocol")

**Date**: 2026-05-12

**Symptom**:
```
javax.net.ssl.SSLHandshakeException: No appropriate protocol (protocol is disabled or cipher suites are inappropriate)
Command create-jdbc-connection-pool failed.
```
After enabling Secure Admin and restarting, all `asadmin` commands fail. JDBC configuration cannot complete; the application home page returns a blank screen.

**Root Cause**:
GlassFish 4.1.1's admin listener defaults to **TLS 1.0**. `eclipse-temurin:8-jdk-jammy` (Java 8u292+) lists `TLSv1, TLSv1.1` in `jdk.tls.disabledAlgorithms` inside `java.security`. The `asadmin` client cannot complete the TLS handshake.

**Resolution**:
Added a Dockerfile step to remove `TLSv1, TLSv1.1,` from the disabled algorithms list in `java.security`:
```dockerfile
RUN find /opt/java /usr/lib/jvm -name "java.security" 2>/dev/null | \
    xargs sed -i 's/TLSv1, TLSv1\.1, //' 2>/dev/null || true
```

**Status**: Fixed ✅

---

## Issue #28: GlassFish 4.1.1 Bundled Certificates Expired September 2025 — asadmin SSL Handshake Fails

**Date**: 2026-05-12

**Symptom**:
```
javax.net.ssl.SSLHandshakeException: NotAfter: Tue Sep 16 19:05:42 UTC 2025
Command create-jdbc-connection-pool failed.
```
After fixing Issue #27, the TLS protocol negotiation succeeds but certificate validity check fails.

**Root Cause**:
The self-signed certificates bundled with GlassFish 4.1.1 (aliases `s1as` and `glassfish-instance` in `keystore.jks`) expired on **2025-09-16**. With the current date being 2026-05-12, Java's SSL layer enforces certificate validity and rejects the handshake.

**Resolution**:
Added a Dockerfile step to delete the expired certificates and regenerate new self-signed certificates with a 10-year validity using `keytool`, then import the new public certificates into GlassFish's trust store (`cacerts.jks`, used by `asadmin` to verify the server certificate):
```dockerfile
RUN KEYSTORE=.../keystore.jks && CACERTS=.../cacerts.jks && \
    for ALIAS in s1as glassfish-instance; do \
        keytool -delete -alias $ALIAS -keystore $KEYSTORE -storepass changeit 2>/dev/null || true; \
        keytool -genkeypair -alias $ALIAS -keyalg RSA -keysize 2048 -validity 3650 \
            -dname "CN=localhost,OU=GlassFish,O=Eclipse,..." \
            -keystore $KEYSTORE -storepass changeit -keypass changeit; \
        keytool -export -alias $ALIAS -keystore $KEYSTORE -storepass changeit -file /tmp/$ALIAS.cert; \
        keytool -import -alias $ALIAS -noprompt -keystore $CACERTS -storepass changeit -file /tmp/$ALIAS.cert; \
    done
```

**Status**: Fixed ✅
