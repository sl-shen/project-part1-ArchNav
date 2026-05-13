# Assignment Requirements and Application Overview

Course: NYU Cloud Computing (CSCI-GA.3033-026)
Professor: Jean-Claude Franchitti
Project: Part I — Application Cloud Migration

---

## I. Assignment Requirements

### Sub-project 1: Install and Run the Original Application
- Follow the steps in `ArchNavInstallationGuide.pdf` to fully install and run the ArchNav application locally
- Components to install: JDK 8, MySQL 8, Oracle JDeveloper 12.2.1.3.0, GlassFish 5, ADF Essentials, Maven, Cygwin, ApacheDS, Apache Directory Studio, Fortress Core/Web/REST, Tomcat 9
- Upon completion, the application should be accessible at `http://localhost:9999/archemy/faces/login.jspx`
- **Note**: JDK 8 is required (JDK 12 causes Fortress build failures due to missing `javax.xml.bind`)

### Sub-project 2: Analyze the Existing Application Architecture
- Gain a thorough understanding of the overall ArchNav architecture
- Identify all technical components and their interdependencies
- Understand how the Oracle ADF BC4J data layer, JSF view layer, and Fortress RBAC security layer work together

### Sub-project 3: Create Architecture Blueprints
- Draw the current application architecture diagram (As-Is architecture)
- Draw the target cloud architecture diagram (To-Be architecture)
- All components must be represented: database, LDAP, security framework, application server, frontend, etc.

### Sub-project 4: Select the Best Migration Strategy
- Refer to the two strategies described in `ArchNav-Application-Migration-Suggestions.pdf`:
  - **Option A (PaaS)**: Deploy the application to a cloud-based Web App Server with cloud storage for the database. Pros: good scalability. Cons: vendor lock-in risk; GlassFish connection pool configuration is challenging in a PaaS environment
  - **Option B (IaaS + Docker)**: Use 4 Docker containers to run MySQL, Tomcat (Fortress-Web + Fortress-REST), ApacheDS, and GlassFish (archemy.ear) separately. Pros: platform-independent, supports Fortress multi-tenancy, Kubernetes-ready
- Justify the chosen strategy and specify the target cloud platform (AWS EC2, IBM Cloud, GCP, Azure, or Oracle Cloud)

### Sub-project 5: Execute Migration and Document
- Migrate the application to the cloud according to the chosen strategy
- Document all steps, issues encountered, and their resolutions
- Provide complete deployment documentation

### Sub-project 6: Demo
- Live demo of the cloud-deployed application to the professor/TA
- Must demonstrate: normal application operation, login, and RBAC access control

---

## II. Application Overview

### 2.1 Application Summary

**ArchNav (Archemy Navigation System)** is a Java EE web application built on the **Oracle ADF Essentials** framework, with integrated enterprise-grade RBAC access control. The application serves as an "architectural knowledge navigation system" that allows users to browse and search architecture-domain data including Domains, Dimensions, Areas, and other classification hierarchies.

### 2.2 Technology Stack

| Layer | Technology | Version |
|-------|------------|---------|
| Frontend UI | Oracle ADF Faces (JSF 2.1) | — |
| Application Framework | Oracle ADF BC4J (Business Components) | ADF Essentials |
| Application Server | GlassFish | 5.0.0 |
| Security Framework | Apache Fortress (RBAC) | 2.0.3 |
| Security Server | Apache Tomcat | 9.0.21 |
| LDAP Directory | ApacheDS | 2.0.0-AM25 |
| Database | MySQL | 8.0.16 |
| Build Tools | Maven (Fortress), JDeveloper (ADF) | 3.6.1 |
| JDK | Java SE Development Kit | 8u212 |
| Auxiliary Web App | Python / Django | 1.10.4 |

### 2.3 Architecture (Four Core Modules)

```
┌─────────────────────────────────────────────────────────┐
│                      User Browser                        │
└──────────────────────────┬──────────────────────────────┘
                           │ HTTP :9999
┌──────────────────────────▼──────────────────────────────┐
│              GlassFish 5 Application Server               │
│  ┌─────────────────────────────────────────────────┐    │
│  │          archemy.ear / Archemy_webapp.war        │    │
│  │  ┌──────────────────┐  ┌──────────────────────┐ │    │
│  │  │  ADF Faces View  │  │  ADF BC4J Data Layer │ │    │
│  │  │  (.jspx pages)   │  │  (Entity/View Objects│ │    │
│  │  └──────────────────┘  └──────────┬───────────┘ │    │
│  │  ┌─────────────────────────────┐  │             │    │
│  │  │  FortressSecurityResolver   │  │             │    │
│  │  │  (EL Resolver for RBAC)     │  │             │    │
│  │  └─────────────────────────────┘  │             │    │
│  └────────────────────────────────────┼────────────┘    │
│              JNDI: jdbcMySQLDataSource │                  │
│              Pool: MySQLConnPool       │                  │
└──────────────────────────┬────────────┼─────────────────┘
                           │            │ JDBC
           HTTP :8080      │   ┌────────▼────────┐
┌──────────▼──────────┐    │   │  MySQL 8 Database│
│  Apache Tomcat 9    │    │   │  schema: archemy │
│  ┌───────────────┐  │    │   └─────────────────┘
│  │ Fortress-Web  │  │    │
│  │ Fortress-REST │  │    │
│  └───────┬───────┘  │    │
└──────────┼──────────┘    │
           │ LDAP :10389   │
┌──────────▼──────────┐    │
│  ApacheDS LDAP      │    │
│  (Users/Roles data) │    │
└─────────────────────┘    │
                           │
┌──────────────────────────▼──────────────────────────────┐
│  Python/Django Web App (archemy-webapp)                   │
│  Port: 8000 (runs independently)                          │
└─────────────────────────────────────────────────────────┘
```

### 2.4 Module Details

#### Module 1: ADF Main Application (`App/` directory)

**ArchemyAppModel (Data Layer — ADF BC4J)**

The Oracle ADF Business Components layer handles all database interactions:

- **Entity Objects**: directly map to database tables
  - `AreasEO` → `areas` table
  - `DimensionsEO` → `dimensions` table
  - `DomainsEO` → `domains` table
  - `IadsEO` → `iads` table
  - `KadsEO` → `kads` table
  - `CustomerInfoEO` → `customerinfo` table

- **View Objects**: provide query views for the UI layer with bindable parameters

- **Application Module**: `ArchemySearchAM` is the service entry point, exposing all business methods to the view layer

- **Database connection**: via GlassFish JNDI datasource `jdbcMySQLDataSource` (pool name `MySQLConnPool`)

**ArchemyAppView (View Layer — ADF Faces/JSF)**

- `login.jspx`: login page
- `changePassword.jspx`: change password page
- Other secured pages (require authentication)
- `FortressSecurityResolver`: ADF EL expression resolver that integrates RBAC permission checks into page rendering
- `faces-config.xml`: JSF configuration

**Deployment Artifacts**
- `Archemy_Project1_webapp.war`: GlassFish deployment package
- `archemy.ear`: WebLogic deployment package (legacy)

#### Module 2: Fortress Security Module (`FortressSecurity/` directory)

An independent Maven project that integrates the Apache Fortress RBAC framework into ArchNav:

- Build artifact: `archemy-security-1.0-SNAPSHOT-jar-with-dependencies.jar`
- Deployment location: copied to GlassFish `domain1/lib/` for the main application to reference
- **RBAC roles**: `Admin` (administrator) and `NormalUser` (regular user), with permission-based page access control

Fortress itself runs on **Tomcat** (Fortress-Web + Fortress-REST), using **ApacheDS** as the LDAP backend to store users, roles, and permission data.

#### Module 3: Database Model (`DB_MODEL/` + `Data/` directories)

- `archemy_schema.mwb`: MySQL Workbench design file with complete E-R diagram and table structure
- `DatabaseImport.sql`: initial data import script providing the base data needed at startup

#### Module 4: Python/Django Web App (`archemy-webapp/` directory)

An independent auxiliary web application:

```
archemy-webapp/
├── manage.py
├── requirements.txt          # Django 1.10.4, Pillow, moviepy, music21, etc.
├── db.sqlite3
├── archemy/                  # Django project config
└── archemywebapp/            # Django app
    ├── models.py             # ArchemywebappUser model (extends Django User)
    ├── views.py
    ├── forms.py
    └── urls.py
```

### 2.5 Data Flow

1. User visits `http://localhost:9999/archemy/faces/login.jspx` in browser
2. GlassFish receives the request; ADF Faces renders the login page
3. User submits credentials; Fortress queries ApacheDS LDAP via the Tomcat REST API to authenticate
4. On success, Fortress returns the user's roles (Admin / NormalUser)
5. ADF Faces pages use `FortressSecurityResolver` to control which features are visible based on the role
6. Data queries flow through ADF BC4J → GlassFish JNDI → MySQL connection pool → MySQL database

### 2.6 Other Resources

- `mockups/`: UI design mockups
- `PythonFundamentals/`: Python fundamentals learning materials (course supplement)
- `ArchNavInstallationGuide.pdf`: 93-page detailed installation guide, the core document for Sub-project 1
- `ArchNav-Application-Migration-Suggestions.pdf`: migration suggestions document, the main reference for Sub-project 4

---

## III. Recommended Migration Path

Based on the available materials, **Option B (IaaS + Docker)** is recommended for the following reasons:

1. GlassFish connection pool configuration is difficult to replicate directly in a PaaS environment
2. Docker containerization precisely reproduces each component version of the local installation
3. The 3-container architecture (MySQL + ApacheDS + GlassFish) cleanly maps to the existing three-tier architecture
4. Once containerized, the stack can be deployed on AWS EC2, satisfying the assignment's cloud platform requirement

---

## IV. Tomcat: Not Used in This Docker Implementation

### Why Tomcat Is Listed in the Requirements

The original installation guide includes Tomcat 9 to host **Fortress-Web** and **Fortress-REST** — two web applications that expose the Fortress RBAC engine as an HTTP/REST API. In the reference architecture, GlassFish calls this REST API to perform permission checks at runtime:

```
Original architecture:
GlassFish → HTTP → Tomcat (Fortress-REST) → LDAP → ApacheDS
```

### Why Tomcat Is Not Needed in Our Implementation

Our Docker implementation eliminates Tomcat entirely by embedding the Fortress Core library directly inside GlassFish. The Fortress JAR files are placed in GlassFish's `domain1/lib/` directory, so the application talks to ApacheDS over LDAP directly without any HTTP intermediary:

```
Our Docker architecture:
GlassFish → LDAP (direct) → ApacheDS
(Fortress Core embedded in GlassFish domain1/lib/)
```

Additionally, the permission check mechanism was changed from `FortressAllowed` to `FortressUserInRole`:

- **`FortressAllowed['obj:op']`** — queries Fortress permission objects (`ftObject` / `ftOperation` LDAP entries) via the REST API. These entries were never created in our LDAP initialization, so it always returns null and all admin menu items are hidden (Debug #25).
- **`FortressUserInRole['RoleName']`** — directly checks whether the authenticated user's RBAC session contains the specified role. This works purely from the LDAP user/role data loaded at initialization, with no dependency on Tomcat or permission objects.

### Result

The final Docker stack uses **3 containers** (MySQL + ApacheDS + GlassFish), not 4. Full RBAC role-based menu visibility works correctly without Tomcat.
