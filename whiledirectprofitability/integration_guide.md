# WhileDirectProfitability — Integration Guide

## Architecture & System Overview

The **RegCheck AI** architecture is a **modular, lightweight system** designed to deliver **real-time compliance alerts** with minimal operational overhead. It consists of four core components—**React frontend, Firebase persistence layer, Python scraping pipeline, and Vercel/Railway deployment**—each optimized for speed, scalability, and ease of maintenance. Below is the **end-to-end topology**, including data flows, dependencies, and deployment specifics.

The **React frontend** is a **single-page application (SPA)** built with **Next.js** (for SSR capabilities) and **Tailwind CSS** for rapid UI iteration. It hosts a **dashboard with three primary views**:
- **Alert Inbox**: A **real-time feed** of compliance deadlines, formatted as **collapsible cards** with deadlines, actions, and evidence status. Each alert includes a **"Mark as Complete"** button that triggers an API call to Firebase, updating the user’s compliance status.
- **Compliance Dashboard**: A **Kanban-style board** showing **past, current, and upcoming** compliance tasks, color-coded by risk level (green = compliant, yellow = pending, red = overdue). Users can **export audit-ready PDFs** with all captured evidence in one click.
- **Settings Panel**: Where users select their **industry, location, and compliance frameworks** (e.g., HIPAA, GDPR, NYC contractor laws). This data is stored in Firebase and used to **filter alerts** from the Python pipeline.

The **Firebase backend** serves as the **primary persistence layer**, storing:
- **User profiles** (email, industry, location, subscription tier).
- **Alert history** (timestamp, regulation source, deadline, user actions).
- **Evidence storage** (screenshots, PDFs, or user-uploaded files) in **Firebase Storage**, with **metadata** (e.g., "HIPAA training certificate") in Firestore.
- **Webhook subscriptions** for Slack/email notifications, stored as **JSON payloads** in Firestore.

The **Python scraping pipeline** runs **nightly on Railway** (a serverless platform) and is triggered by:
1. **User-reported gaps** (via a **"Report Missing Regulation"** form in the dashboard).
2. **Scheduled checks** for **public data sources** (e.g., state government APIs, OSHA updates, GDPR guidelines).
3. **Webhook events** from Firebase (e.g., when a user updates their industry/location).

The pipeline consists of three stages:
- **Source Scraping**: Uses **BeautifulSoup** and **Scrapy** to extract **deadlines, actions, and evidence requirements** from:
  - **State government websites** (e.g., `calbbs.ca.gov` for CA therapists).
  - **OSHA, GDPR, and HIPAA official portals**.
  - **User-submitted links** (e.g., "This city just added a new ADA rule—here’s the link").
- **Rule-Based Parsing**: Applies **regex patterns** to extract:
  - **Deadlines** (e.g., `"Renew by [MM/DD/YYYY]"` → `{"due_date": "2024-12-31"}`).
  - **Actions** (e.g., `"Submit Form X"` → `{"action": "submit_renewal"}`).
  - **Evidence requirements** (e.g., `"Save your confirmation email"` → `{"evidence_type": "email"}`).
- **Alert Generation**: Pushes **structured JSON payloads** to Firebase via **Firestore triggers**, which then **notifies the frontend** via **real-time updates** (using Firebase’s `onSnapshot` listener).

The **deployment stack** is **serverless-first** to minimize costs and operational overhead:
- **Frontend**: Hosted on **Vercel**, with **Next.js API routes** for:
  - Authentication (via Firebase Auth).
  - Webhook endpoints (e.g., `/webhooks/slack` for notification routing).
  - Evidence uploads (multipart/form-data to Firebase Storage).
- **Backend**: **Railway** runs the Python pipeline in a **Docker container** (1GB RAM, 1 vCPU), scheduled via **Cron jobs** (nightly at 2 AM UTC).
- **Database**: **Firestore** for structured data (users, alerts, settings) and **Firebase Storage** for unstructured evidence (screenshots, PDFs).
- **Notifications**: **Slack/email webhooks** are triggered via **Firebase Cloud Functions** when:
  - A new alert is generated.
  - A user marks an alert as complete (to confirm compliance).
  - An audit risk is detected (e.g., missing evidence).

**Worked Example: A Therapist in California Renews Their License**
1. **User Action**: A therapist in California logs into RegCheck AI and selects **"Licensed Therapist"** under **industry** and **"California"** under **location**.
2. **Pipeline Trigger**: The next night, the Python scraper runs and finds a **CA BBS license renewal deadline** (due 12/31/2024) on `calbbs.ca.gov`.
3. **Alert Generation**: The scraper parses the deadline, action (`"Renew license"`), and evidence requirement (`"Save confirmation email"`), then pushes this to Firebase as:
   ```json
   {
     "user_id": "user_abc123",
     "regulation": {
       "name": "CA BBS License Renewal",
       "source": "https://calbbs.ca.gov",
       "deadline": "2024-12-31",
       "action": "Renew license",
       "evidence_required": "email"
     },
     "status": "pending",
     "created_at": "2024-10-15T12:00:00Z"
   }
   ```
4. **Frontend Update**: The therapist’s dashboard receives a **real-time update** via Firestore’s `onSnapshot`, displaying the alert in their inbox:
   > **🚨 Your CA BBS license renewal is due in 67 days.**
   > **Action**: Renew your license by [12/31/2024].
   > **Evidence**: Save your confirmation email here → [upload button].
   > **Source**: [calbbs.ca.gov](https://calbbs.ca.gov)
5. **User Compliance**: The therapist renews their license, uploads the confirmation email via the dashboard, and clicks **"Mark as Complete"**. This triggers:
   - A Firebase Cloud Function to **update the alert status** to `"completed"`.
   - A Slack notification to their workspace:
     > **RegCheck AI Alert**: ✅ CA BBS License Renewal marked complete. Evidence saved.
6. **Audit Export**: During an audit, the therapist exports a **PDF** from the dashboard, which includes:
   - The alert details (deadline, action).

## Authentication & Security

Firebase Authentication is the backbone of **WhileDirectProfitability’s RegCheck AI**, ensuring secure, scalable, and role-aware access for solopreneurs, agencies, and SaaS teams. Below is the **exact implementation** for JWT validation, role-based access control (RBAC), and integration with Firebase Auth, with worked examples for each user type.

---

****Firebase Auth Setup****
RegCheck AI uses **Firebase Authentication** for user onboarding, with **email/password + Google OAuth** as the primary sign-up methods. Firebase handles **password hashing, session management, and multi-factor authentication (MFA)** out of the box, reducing backend complexity.

**Key Configuration:**
```javascript
// firebase.js (client-side)
import { initializeApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, signInWithPopup } from "firebase/auth";

const firebaseConfig = {
  apiKey: "YOUR_API_KEY",
  authDomain: "regcheck-ai.firebaseapp.com",
  projectId: "regcheck-ai",
  storageBucket: "regcheck-ai.appspot.com",
  messagingSenderId: "1234567890",
  appId: "1:1234567890:web:abc123def456"
};

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const provider = new GoogleAuthProvider();

export { auth, provider, signInWithPopup };
```

**Server-Side Validation (Node.js + Firebase Admin SDK):**
```javascript
// server/auth.js
const { getAuth } = require("firebase-admin/auth");
const admin = require("firebase-admin");

admin.initializeApp();

/**
 * Validates Firebase ID token and extracts user role.
 * @param {string} idToken - Firebase ID token from client.
 * @returns {Promise<{user: Firebase.User, role: string}>}
 */
async function validateToken(idToken) {
  try {
    const decodedToken = await admin.auth().verifyIdToken(idToken);
    const user = await admin.auth().getUser(decodedToken.uid);

    // Assign role based on Firebase custom claims (set during sign-up)
    const role = user.customClaims?.role || "solopreneur";
    return { user, role };
  } catch (error) {
    console.error("Token validation failed:", error);
    throw new Error("Unauthorized: Invalid token");
  }
}
```

---

****JWT Token Validation Rules****
RegCheck AI enforces **strict JWT validation** to prevent token tampering. Firebase’s default tokens include:
- **`authTime`** (timestamp of authentication)
- **`uid`** (unique user ID)
- **`email`** (user’s email)
- **`customClaims`** (role-based permissions)

**Middleware Example (Express.js):**
```javascript
// server/middleware/auth.js
const { validateToken } = require("./auth");

async function authMiddleware(req, res, next) {
  const idToken = req.headers.authorization?.split("Bearer ")[1];
  if (!idToken) {
    return res.status(401).json({ error: "Authorization token required" });
  }

  try {
    const { user, role } = await validateToken(idToken);
    req.user = { uid: user.uid, email: user.email, role };
    next();
  } catch (error) {
    res.status(403).json({ error: error.message });
  }
}
```

**Token Expiry & Refresh:**
- Firebase tokens **expire in 1 hour** by default. RegCheck AI implements a **refresh token flow** via Firebase’s `reauthenticate` API.
- Example refresh request:
  ```javascript
  // Client-side refresh logic
  async function refreshToken(currentToken) {
    const refreshToken = await admin.auth().refreshSession(currentToken);
    return refreshToken.accessToken;
  }
  ```

---

****Role-Based Access Control (RBAC)****
RegCheck AI supports **three roles**, each with distinct permissions:

1. **Solopreneur** (`role: "solopreneur"`):
   - Access to **personal compliance dashboard**.
   - **Limited to 1 user account** (no multi-tenancy).
   - **Audit exports** capped at **5 files/month**.
   - **Example Firebase Custom Claim:**
     ```json
     {
       "role": "solopreneur",
       "industry": "healthcare",
       "location": "California"
     }
     ```

2. **Agency** (`role: "agency"`):
   - **Multi-tenant support** (manages **unlimited clients**).
   - **White-label branding** (custom domain, logo).
   - **Priority support** (24-hour response).
   - **Example Custom Claim:**
     ```json
     {
       "role": "agency",
       "clients": ["client123", "client456"],
       "whiteLabel": true
     }
     ```

3. **SaaS Team** (`role: "saas"`):
   - **Compliance-as-code** (API access to RegCheck’s parsing engine).
   - **Custom framework support** (e.g., SOC 2, ISO 27001).
   - **Bulk evidence uploads** (for automated compliance checks).
   - **Example Custom Claim:**
     ```json
     {
       "role": "saas",
       "apiKey": "sk_abc123...",
       "allowedFrameworks": ["soc2", "gdp"]
     }
     ```

**Setting Roles During Sign-Up (Server-Side):**
```javascript
// server/signup.js
const admin = require("firebase-admin");

async function createUser(userData) {
  const { email, password, role, industry, location } = userData;

  const userRecord = await admin.auth().createUser({
    email,
    password,
    emailVerified: false,
    customClaims: {
      role,
      industry,
      location
    }
  });

  // Set initial token with claims
  const customToken = await admin.auth().createCustomToken(userRecord.uid, {
    role,
    industry,
    location
  });

  return customToken;
}
```

---

****Worked Example: Solopreneur Sign-Up Flow****
1. **User visits `/signup`**, clicks "Sign Up with Email".
2. **Firebase Auth** creates a user with `email/password` and **no initial role**.
3. **Server sets custom claims** (role, industry, location) via `createCustomToken`.
4. **Client receives JWT** with embedded claims:
   ```json
   {
     "uid": "user123",
     "email": "therapist@example.com",
     "role": "solopreneur",
     "industry": "healthcare",
     "location": "California",
     "iat": 1712345678,
     "exp": 1712432078

## Core API Endpoints & Routing

The **Core API Endpoints & Routing** for WhileDirectProfitability’s **RegCheck AI** are designed to be **minimal, RESTful, and immediately actionable**—built for a lightweight backend that prioritizes speed of development over scalability. The system follows a **single-responsibility principle** for each endpoint, ensuring clarity for developers and reliability for compliance tracking. Below are the exact specifications, including request/response payloads, authentication flows, and error handling—everything a developer needs to integrate RegCheck AI into their workflow without ambiguity.

---

The API is structured around **four core domains**:
1. **User Profiles** – Manages user settings, industries, and locations.
2. **Rule Configuration** – Defines which regulations apply to a user’s context.
3. **Regulatory Alerts Inbox** – Streams and retrieves compliance alerts.
4. **Evidence Logs** – Captures and exports audit-ready proof.

All endpoints use **JWT-based authentication** with a **Firebase Admin SDK** for session management. Rate limits are enforced at the **user-level** (100 requests/minute) and **IP-level** (500 requests/minute) to prevent abuse. Errors return standardized responses with `HTTP 4xx` or `5xx` status codes, including `error_code`, `message`, and `retry_after` (if applicable).

---

****User Profiles Endpoints****
These endpoints handle user onboarding, industry/location selection, and profile updates. All payloads are **JSON**, and responses include `user_id` for subsequent requests.

****1. `POST /api/v1/users/register`****
Creates a new user account and initializes their compliance profile. Requires **email verification** (sent via Firebase Auth) before full access.

**Request:**
```http
POST /api/v1/users/register
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "SecurePass123!",
  "first_name": "Alex",
  "last_name": "Chen",
  "industry": "healthcare_professional",  // Predefined enum: contractor, therapist, accountant, etc.
  "location": {
    "city": "New York",
    "state": "NY",
    "country": "US",
    "zip_code": "10001"
  },
  "timezone": "America/New_York"
}
```

**Response (201 Created):**
```json
{
  "user_id": "user_abc123xyz",
  "email_verified": false,
  "industry": "healthcare_professional",
  "location": {
    "city": "New York",
    "state": "NY",
    "country": "US"
  },
  "next_steps": {
    "verify_email": "Check your inbox for a verification link.",
    "configure_alerts": "Set up your compliance alerts in the dashboard."
  }
}
```

**Response (400 Bad Request):**
```json
{
  "error_code": "invalid_industry",
  "message": "Industry 'healthcare_professional' is not supported for this API version. Use 'therapist' or 'doctor' instead.",
  "retry_after": null
}
```

**Authentication:**
- **Method:** `POST`
- **Headers:** `Content-Type: application/json`
- **Body:** Required fields as above.

---

****2. `GET /api/v1/users/{user_id}/profile`****
Retrieves a user’s full profile, including **applied regulations** and **compliance status**. Used for dashboard rendering.

**Request:**
```http
GET /api/v1/users/user_abc123xyz/profile
Authorization: Bearer <JWT_TOKEN>
```

**Response (200 OK):**
```json
{
  "user_id": "user_abc123xyz",
  "email": "user@example.com",
  "industry": "therapist",
  "location": {
    "city": "Los Angeles",
    "state": "CA",
    "country": "US"
  },
  "applied_regulations": [
    {
      "regulation_id": "hipaa_2024",
      "name": "HIPAA Privacy Rule (2024)",
      "status": "active",
      "last_checked": "2024-05-15T14:30:00Z",
      "next_check": "2024-06-15T14:30:00Z"
    },
    {
      "regulation_id": "ca_bbs_license",
      "name": "California Board of Behavioral Sciences License",
      "status": "overdue",
      "last_checked": "2024-05-10T09:15:00Z",
      "next_check": "2024-06-10T09:15:00Z",
      "alerts": 3
    }
  ],
  "compliance_score": 0.72,  // 0.0 (critical) to 1.0 (fully compliant)
  "created_at": "2024-05-01T10:00:00Z"
}
```

**Response (404 Not Found):**
```json
{
  "error_code": "user_not_found",
  "message": "User with ID 'user_abc123xyz' does not exist."
}
```

**Authentication:**
- **Method:** `GET`
- **Headers:** `Authorization: Bearer <JWT_TOKEN>`
- **Query Params:** None.

---

****3. `PUT /api/v1/users/{user_id}/update`****
Updates a user’s profile, including **industry, location, or contact details**. Triggers a **re-scan of applicable regulations** if location/industry changes.

**Request:**
```http
PUT /api/v1/users/user_abc123xyz/update
Authorization: Bearer <JWT_TOKEN>
Content-Type: application/json

{
  "location": {
    "city": "San Francisco",
    "state": "CA",
    "country": "US"
  },
  "contact_phone": "+1234567890"
}
```

**Response (200 OK):**
```json
{
  "message": "Profile updated successfully. Regulation scan triggered.",
  "regulation_scan_status": "queued",
  "scan_completion_estimate": "Within 5 minutes"
}
```

**Response (400 Bad Request):**
```json
{
  "error_code": "invalid_location",
  "message": "City 'San Francisco' is not recognized in state 'CA'. Valid cities: Los Angeles, San Diego, etc."
}
```

**Authentication:**
- **Method:** `PUT`
- **Headers:** `Authorization: Bearer <JWT_TOKEN>`, `Content-Type: application/json`

## Data Schemas & Database Models

The **Data Schemas & Database Models** for WhileDirectProfitability’s **RegCheck AI** are designed to balance **real-time compliance tracking** with **minimal operational overhead**. Since the product relies on **public data sources** (state government APIs, OSHA, GDPR guidelines) and **user-reported gaps**, the database must efficiently store **regulations, alerts, user actions, and audit evidence** while ensuring **fast query performance** for the core workflow: *"Show me all pending deadlines for my industry + location, with attached evidence."*

The schema leverages **Firebase Firestore** (for its real-time sync and offline capabilities) and **supports nested documents** to model hierarchical relationships—e.g., a `Regulation` contains multiple `Alerts`, each with associated `Evidence`. Below are the exact JSON structures and NoSQL document models, optimized for **low-latency reads** (critical for alert notifications) and **minimal write operations** (to avoid Firebase’s 1MB document limit).

---

****1. User Schema****
Each user is a **document in the `users` collection**, with subcollections for their compliance data. The schema prioritizes **minimal fields** to reduce write costs while capturing essential metadata for segmentation (e.g., industry, location) and monetization (e.g., tier, last payment date).

```json
{
  "userId": "user_1234567890", // Firebase UID
  "email": "therapist@example.com",
  "name": "Dr. Jane Doe",
  "industry": "healthcare_mental_health", // Predefined enum
  "location": {
    "state": "CA",
    "city": "San Francisco",
    "zip": "94105",
    "county": "San Francisco" // Critical for local laws (e.g., NYC vs. SF)
  },
  "company": {
    "name": "San Francisco Therapy Collective",
    "type": "sole_proprietorship", // For tax/compliance tiers
    "employees": 0
  },
  "complianceTier": "free", // "free", "pro", "enterprise"
  "lastPaymentDate": "2024-05-15T00:00:00Z",
  "createdAt": "2024-01-10T12:00:00Z",
  "updatedAt": "2024-05-20T08:30:00Z",
  "settings": {
    "notificationPreferences": {
      "email": true,
      "slack": false,
      "push": true
    },
    "auditFrequency": "monthly" // "monthly", "quarterly", or "annual"
  },
  "metadata": {
    "riskScore": 0.72, // Calculated from pending alerts/evidence gaps
    "lastAudit": null // ISO string or null if never audited
  }
}
```

**Key Notes:**
- **`industry` and `location`** are **predefined enums** (stored in a separate `config/industries` and `config/locations` collection) to enforce consistency and enable **fast filtering** (e.g., "Show all CA healthcare regulations").
- **`complianceTier`** determines access to features like **audit exports** and **multi-user support**.
- **`riskScore`** is a **weighted average** of:
  - Pending alerts (30%),
  - Missing evidence (50%),
  - Industry-specific risk factors (e.g., HIPAA vs. OSHA) (20%).

---

****2. Regulation Schema****
Regulations are **stored as documents in the `regulations` collection**, with a **one-to-many relationship** to `alerts`. Each regulation includes:
- **Source metadata** (e.g., "CA BBS License Renewal"),
- **Jurisdictional scope** (state, city, industry),
- **Plain-language summary** (for non-legal users),
- **Deadline logic** (e.g., "every 2 years on March 15").

```json
{
  "regulationId": "reg_ca_bbs_license_renewal_2024",
  "name": "California Board of Behavioral Sciences License Renewal",
  "source": {
    "url": "https://www.bbs.ca.gov/licensees/renewal/",
    "api": "ca_bbs_api", // Reference to a public API or scraper config
    "lastUpdated": "2024-05-10T00:00:00Z",
    "confidenceScore": 0.95 // 0–1, based on source reliability (e.g., government site > forum post)
  },
  "jurisdiction": {
    "state": "CA",
    "city": null,
    "county": null,
    "industry": "healthcare_mental_health",
    "specificSubindustry": "licensed_clinical_social_worker"
  },
  "summary": {
    "plainText": "Your CA BBS license must be renewed every 2 years by March 1st. Fees: $200 for online renewal.",
    "jargon": {
      "license": "Board of Behavioral Sciences license",
      "renewal": "Biennial renewal",
      "fee": "$200 (non-refundable)"
    }
  },
  "requirements": [
    {
      "type": "document",
      "name": "renewal_form",
      "description": "Completed renewal form (available on BBS website)",
      "evidenceField": "renewal_form_screenshot" // Reference to Evidence document
    },
    {
      "type": "payment",
      "name": "fee_payment",
      "description": "Proof of $200 payment to BBS",
      "evidenceField": "payment_receipt"
    },
    {
      "type": "training",
      "name": "ethics_continuing_education",
      "description": "40 hours of ethics CE completed in the past 2 years",
      "evidenceField": "ce_certificate"
    }
  ],
  "deadlineLogic": {
    "pattern": "every_2_years_on_march_1st",
    "nextDeadline": "2024-03-01T00:00:00Z",
    "lastRenewalDate": "2022-03-01T00:00:00Z",
    "isOverdue": false
  },
  "severity": "high", // "low", "medium", "high", "critical"
  "createdAt": "2023-11-15T00:00:00Z",
  "updatedAt": "

## Rule-Based Parsing & Scraping Pipeline

The **Rule-Based Parsing & Scraping Pipeline** is the backbone of WhileDirectProfitability’s **RegCheck AI**, transforming raw public data into actionable, plain-language compliance alerts. Unlike traditional AI models that rely on deep learning or large datasets, this system uses **rule-based keyword matching, structured scraping, and deadline logic** to parse regulations from public sources (e.g., state government websites, OSHA, GDPR guidelines) and generate alerts tailored to the user’s industry and location. Below is the exact technical implementation, including scraping logic, alert generation parameters, and evidence capture workflows—ready for a developer to deploy.

---

The pipeline consists of three core components: **1) a Python-based scraper**, **2) a rule engine for keyword matching and deadline extraction**, and **3) a plain-language generator**. The scraper fetches updates from predefined public sources (e.g., `https://www.cabbs.ca.gov/licensing/renewals`, `https://www.nyc.gov/site/doitt/construction/licenses.shtml`) using **BeautifulSoup** for HTML parsing and **requests** for rate-limited API calls. Keyword matching is handled via **regex patterns** and **predefined rule sets** (e.g., `/renewal.*due.*(\d{1,2})[/-]\d{4}/` to capture deadlines). Deadlines are validated against a **timezone-aware datetime** library to ensure accuracy for users across time zones.

Here’s a worked example of how the scraper processes a **NYC contractor permit renewal notice** from the NYC Department of Buildings (DOB) website:

```python
import requests
from bs4 import BeautifulSoup
import re
from datetime import datetime, timedelta

def scrape_dob_renewals():
    url = "https://www.nyc.gov/site/doitt/construction/licenses.shtml"
    response = requests.get(url, headers={"User-Agent": "WhileDirectProfitability/1.0"})
    soup = BeautifulSoup(response.text, 'html.parser')

    # Extract renewal notices from the "Renewals" section
    notices = soup.find_all('div', class_='notice')
    for notice in notices:
        text = notice.get_text()
        # Rule 1: Extract deadline (e.g., "Due by March 31, 2025")
        deadline_match = re.search(r'due by (\w+ \d{1,2}, \d{4})', text, re.IGNORECASE)
        if deadline_match:
            deadline_str = deadline_match.group(1)
            deadline = datetime.strptime(deadline_str, "%B %d, %Y")
            # Rule 2: Extract license type (e.g., "Contractor License")
            license_type = re.search(r'(\w+ \w+) License', text, re.IGNORECASE)
            if license_type:
                license_type = license_type.group(1)
                # Rule 3: Extract fine amount (e.g., "Fines up to $500")
                fine_match = re.search(r'fines up to (\$[\d,]+)', text, re.IGNORECASE)
                fine = fine_match.group(1) if fine_match else "$0"
                # Rule 4: Extract renewal link
                link = notice.find('a')['href'] if notice.find('a') else "#"
                # Generate alert payload
                alert = {
                    "regulation": "NYC Contractor License Renewal",
                    "industry": "Construction",
                    "location": "New York City",
                    "deadline": deadline.strftime("%B %d, %Y"),
                    "action": f"Renew your {license_type} license by the deadline to avoid {fine}.",
                    "source": url,
                    "link": link,
                    "severity": "high" if deadline < datetime.now() + timedelta(days=30) else "medium",
                    "evidence_required": ["license_renewal_confirmation_email"]
                }
                yield alert
```

The scraper runs **daily at 2 AM UTC** (configurable via cron) and pushes updates to a **Firebase Firestore** collection named `regulations`. Each alert includes:
- **Plain-language action items** (e.g., *"Renew your HIPAA training certificate by June 15, 2025"*).
- **Deadline validation** (e.g., flags alerts within 30 days as "high severity").
- **Evidence requirements** (e.g., `license_renewal_confirmation_email` or `screenshot_of_osha_compliance_form`).

The **plain-language generator** uses a **predefined template library** to translate legal jargon into user-friendly alerts. For example:
```python
def generate_alert_message(alert_data):
    templates = {
        "license_renewal": """
🚨 Your {license_type} license in {location} is due for renewal by {deadline}.
Action: {action}.
Source: {source}
Evidence needed: {evidence_required}.
""",
        "training_certificate": """
⚠️ Your {certificate_type} training expired on {expiry_date}.
Action: Complete the renewal at {link}.
Evidence needed: {evidence_required}.
"""
    }
    return templates[alert_data["type"]].format(**alert_data)
```

---
**Keyword Matching Rules:**
The system uses **three layers of rules** to ensure accuracy:
1. **Deadline Extraction:**
   - Regex patterns for common date formats (e.g., `MM/DD/YYYY`, `Month Day, Year`, `due in X days`).
   - Example: `/due by (\w+ \d{1,2}, \d{4})|expires on (\w+ \d{1,2}, \d{4})/` captures deadlines in plain text.
2. **Industry-Specific Triggers:**
   - Predefined keywords per industry (e.g., `HIPAA`, `SOC 2`, `OSHA 1910.120` for healthcare; `GDPR`, `CCPA` for SaaS).
   - Example: If the user selects "Therapist," the scraper prioritizes alerts containing `HIPAA`, `CA BBS`, or `NY State Education Department`.
3. **Location-Based Filters:**
   - State/province/city-specific terms (e.g., `NYC`, `California`, `Texas`) to narrow alerts.
   - Example: A user in `Austin, TX` will receive alerts tagged with `Texas Department of Licensing and Regulation`.

---
**Evidence Capture Workflow:**
When a user takes action (e.g., renews a license), the system **auto-captures proof** via:
1. **Email Screenshots:**
   - Users paste confirmation emails into a **dedicated Slack channel** or **email inbox** (configured in settings).
   - The system **scrapes the email body** for keywords like `confirmation`, `

## Evidence Capture & Audit Export

RegCheck AI’s **Evidence Capture & Audit Export** subsystem is the backbone of its compliance assurance—it transforms passive alerts into **audit-proof documentation** with minimal user effort. The system automatically captures, organizes, and exports evidence for every regulation tracked, ensuring users can prove compliance in seconds during inspections or audits. Below is the exact implementation, including mechanisms for auto-saving emails, capturing verification screenshots, and compiling single-file PDF exports.

---

The system operates on a **hybrid of automated capture and user-triggered uploads**, prioritizing automation where possible while allowing manual overrides for complex cases. For example, when RegCheck detects a **license renewal deadline** (e.g., a California BBS therapist license), it:
1. **Auto-saves the renewal confirmation email** (via Gmail/Outlook API) as a PDF attachment in the user’s dashboard.
2. **Captures a screenshot** of the confirmation page (using Puppeteer) if the user clicks a "Verify Now" button.
3. **Links the evidence to the alert** in the dashboard, marking it as "Complete" if both the deadline passes and proof is attached.

This approach eliminates manual documentation while ensuring **100% traceability** for auditors.

---

****1. Auto-Saving Email Attachments & Verification Proof****
RegCheck integrates with **Gmail, Outlook, and Slack** to capture compliance-related emails and attachments automatically. The workflow is triggered by **keyword matching** in the subject/body (e.g., "Your HIPAA training certificate is ready," "NYC contractor license renewed") or **user-configured filters**.

****Implementation Steps:****
- **Step 1: API Setup**
  Use the **Gmail API** (for Gmail users) and **Outlook Graph API** (for Outlook users) to monitor inboxes for compliance-related emails. The API polls the inbox every **15 minutes** (adjustable via user settings) and checks for:
  - **Subject keywords**: `renewal`, `certificate`, `approval`, `compliance`, `license`, `audit`, `verified`.
  - **Body keywords**: `valid through`, `expires on`, `confirmation`, `successful submission`, `your application is approved`.
  - **Attachments**: PDFs, images, or screenshots labeled with compliance terms (e.g., "HIPAA Training," "OSHA Inspection").

  Example Gmail API request payload to fetch emails:
  ```json
  {
    "q": "subject:(renewal OR certificate) OR body:(valid through OR expires)",
    "maxResults": 50,
    "labelIds": ["INBOX"]
  }
  ```

- **Step 2: Evidence Extraction**
  When a matching email is found, RegCheck:
  - **Extracts the email body** and saves it as plain text + HTML.
  - **Downloads attachments** (e.g., PDF certificates, screenshots) and stores them in **Firebase Storage** with a metadata tag linking it to the relevant regulation alert.
  - **Captures screenshots** of verification pages (e.g., license renewal confirmations) using **Puppeteer** if the user clicks a "Verify Now" button in the dashboard. The screenshot is saved with a timestamp and linked to the alert.

  Example metadata structure for an email attachment:
  ```json
  {
    "alertId": "reg_hipaa_training_2024",
    "userId": "user_12345",
    "type": "email_attachment",
    "fileUrl": "https://firebasestorage.../hipaa_cert.pdf",
    "fileName": "HIPAA_Training_Certificate_2024.pdf",
    "timestamp": "2024-05-20T14:30:00Z",
    "status": "verified",
    "source": "gmail"
  }
  ```

- **Step 3: User Confirmation & Manual Overrides**
  Users can **manually upload evidence** via drag-and-drop in the dashboard or via email (e.g., forwarding a compliance document to `support@regcheck.ai`). These files are processed identically to auto-captured evidence, with the addition of a **user-verified timestamp**.

---

****2. Capturing Verification Screenshots****
For regulations requiring **visual proof** (e.g., license renewals, OSHA inspection photos, or website compliance badges), RegCheck provides a **one-click screenshot capture** mechanism. This is triggered when:
- The user clicks a **"Verify Now"** button in the alert dashboard.
- The system detects a **publicly accessible verification page** (e.g., a state government portal confirming a license renewal).

****Implementation Steps:****
- **Step 1: User-Initiated Capture**
  When a user clicks **"Verify Now"** on a license renewal alert, RegCheck:
  1. Opens the verification URL in a **headless browser** (Puppeteer).
  2. Takes a **screenshot** of the page with a **timestamp overlay** (e.g., "Verification captured on May 20, 2024").
  3. Saves the screenshot to Firebase Storage with metadata linking it to the alert.

  Example Puppeteer script snippet:
  ```javascript
  const screenshot = await page.screenshot({
    type: 'png',
    fullPage: true,
    omitBackground: true
  });
  await fs.writeFileSync(
    `./screenshots/${alertId}.png`,
    screenshot,
    'base64'
  );
  ```

- **Step 2: Auto-Capture for Public Verification Pages**
  For regulations where verification is **publicly accessible** (e.g., a state’s "business license lookup" page), RegCheck can **automatically capture screenshots** of the verification status every **30 days** or when the alert is marked as "due." This ensures users don’t miss critical visual proof.

  Example workflow for an OSHA inspection photo:
  1. User receives an alert: *"⚠️ Your OSHA inspection photo is due in 30 days. [Capture Now]."*
  2. User clicks **"Capture Now"** and takes a photo of their workplace compliance board.
  3. RegCheck **auto-captures the photo** (via mobile app or browser upload) and links it to the alert.

---

****3. Compiling Audit-Ready PDF Exports****
The **cornerstone of RegCheck’s value proposition** is its ability to **compile all compliance evidence into a single, searchable PDF** for audits. This PDF includes:
- **Alert summaries** (regulation name, deadline, status).
- **Auto-captured evidence** (emails, screenshots, attachments).
- **User-uploaded documents** (e.g., manual compliance logs).
- **A timestamped audit trail** showing when each piece of evidence was captured.

****Implementation Steps:****
- **Step 1: Dashboard Evidence Compilation**

## Webhook & Notification Subsystem

The **Webhook & Notification Subsystem** is the backbone of WhileDirectProfitability’s real-time compliance alerts, ensuring users receive actionable updates via Slack, email, and third-party integrations without manual checks. This subsystem dispatches events asynchronously, processes them through a lightweight rule engine, and delivers notifications with context—all while maintaining scalability for future integrations like Zapier or Microsoft Teams. Below is the exact implementation, including configuration, payloads, and error-handling logic, so developers can deploy it immediately.

---

****Real-Time Event Dispatching****
The subsystem uses **Firebase Cloud Functions** for event triggers and **Pub/Sub** for queuing notifications. When a new regulation is detected (e.g., a NYC contractor permit renewal), the system emits an event with metadata like `regulation_id`, `deadline`, `severity`, and `required_evidence`. Here’s how it works:

****1. Event Schema & Payload****
Every event follows this structure (JSON):

```json
{
  "event_type": "compliance_alert" | "audit_reminder" | "evidence_required",
  "regulation_id": "reg-nyc-2024-0042",
  "user_id": "user-xyz123",
  "industry": "construction",
  "location": "New York City",
  "deadline": "2024-06-15T00:00:00Z",
  "severity": "high" | "medium" | "low",
  "title": "NYC Contractor Permit Renewal Due",
  "description": "Your NYC contractor license expires on June 15, 2024. Renewal required to avoid fines up to $500.",
  "source_url": "https://www.nyc.gov/doit/permits",
  "required_evidence": [
    {
      "type": "document",
      "description": "Renewal confirmation email",
      "attachment": null // Filled via evidence capture
    }
  ],
  "created_at": "2024-05-20T14:30:00Z",
  "metadata": {
    "scrape_source": "nyc.gov/doit/api/v1/permits",
    "last_updated": "2024-05-20T14:30:00Z"
  }
}
```

****2. Dispatch Configuration****
Events are triggered via **Firebase Cloud Functions** with these triggers:
- **Database writes**: When a new regulation is parsed (e.g., from the scraping pipeline).
- **Timer-based**: For recurring deadlines (e.g., quarterly tax filings).
- **Webhook calls**: From external sources (e.g., a user-reported gap in local laws).

**Example Cloud Function (Node.js):**
```javascript
const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { PubSub } = require("@google-cloud/pubsub");

admin.initializeApp();
const pubsub = new PubSub();

exports.dispatchComplianceAlert = functions.firestore
  .document("regulations/{regId}")
  .onCreate(async (snapshot, context) => {
    const regData = snapshot.data();
    const event = {
      event_type: "compliance_alert",
      regulation_id: context.params.regId,
      user_id: regData.user_id,
      // ... (fill other fields from regData)
    };

    await pubsub.topic("compliance_events").publishJSON(event);
    return null;
  });
```

---

****Notification Channels****
Notifications are dispatched via **Slack**, **email**, and **webhooks** (for future integrations). Each channel has its own template and error-handling logic.

****1. Slack Notifications****
Slack is configured via **incoming webhooks** with a predefined payload. Users set up their Slack channel during onboarding.

**Payload Template:**
```json
{
  "text": ":bell: **Compliance Alert** – {{title}}",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": `*{{title}}*\n{{description}}\n*Deadline:* <{{deadline}}|${new Date(deadline).toLocaleDateString()}>`
      }
    },
    {
      "type": "actions",
      "elements": [
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "View Details"
          },
          "url": "{{source_url}}",
          "style": "primary"
        }
      ]
    }
  ]
}
```

**Error Handling:**
- If Slack fails (e.g., rate limits), the event is **queued for retry** (max 3 attempts).
- Failed events are logged in Firestore under `notifications/failed`.

****2. Email Alerts****
Emails are sent via **SendGrid** with a transactional template. Users configure their email during signup.

**Example Email (HTML):**
```html
<!DOCTYPE html>
<html>
<head>
  <title>Compliance Alert from WhileDirectProfitability</title>
</head>
<body>
  <h1>🚨 Compliance Alert: {{title}}</h1>
  <p>{{description}}</p>
  <p><strong>Deadline:</strong> <a href="{{source_url}}">{{deadline}}</a></p>
  <p><a href="{{action_url}}">Mark as Complete</a></p>
</body>
</html>
```

**Error Handling:**
- **Bounces**: Soft bounces (e.g., full inbox) are retried once. Hard bounces (invalid email) are logged and removed from the user’s preferences.
- **Spam flags**: Monitor SendGrid metrics and adjust sender reputation if needed.

****3. Webhook Integrations****
For future integrations (e.g., Zapier, Notion), the system exposes a **public webhook endpoint** with the same event payload. Users can subscribe via their dashboard.

**Endpoint:**
```
POST https://api.whiledirectprofitability.com/webhooks/compliance
Headers:
  Authorization: Bearer {{user_api_key}}
  Content-Type: application/json
```

**Example Webhook Payload (Same as Event Schema):**
```json
{
  "event_type": "compliance_alert",
  "regulation_id": "reg-nyc-2024-0042",
  "user_id": "user-xyz123",
  // ... (full payload)
}
```

**Error Handling:**
- **Rate limiting**: Enforce 100 requests/minute per user.
- **Validation**: Reject malformed payloads with `400 Bad Request`.

---

****Worked Example: End-to-End Flow****
Let’s walk through a **NYC contractor permit renewal** alert:

1. **Trigger**: The scraping pipeline detects a new regulation (`

## Error Handling & Rate Limiting

**Error Handling & Rate Limiting** in WhileDirectProfitability’s RegCheck AI is designed to balance reliability, security, and scalability while ensuring fair usage across subscription tiers. The system prioritizes **predictable error responses** for developers and **graceful degradation** for end-users, with strict rate limits to prevent abuse and ensure equitable access to the API. Below are the standardized schemas, HTTP status codes, and tier-specific guardrails that developers must implement to integrate seamlessly.

---

The API adheres to a **JSON-based error response schema** that follows REST conventions while including compliance-specific metadata. Every error response includes:
- A **`status`** field (HTTP status code as a string for consistency).
- A **`code`** field (a unique identifier for the error type, e.g., `RATE_LIMIT_EXCEEDED`).
- A **`message`** field (human-readable explanation for developers).
- A **`details`** field (optional, contains technical or contextual data, e.g., retry-after timestamp).
- A **`compliance_impact`** field (a severity level: `CRITICAL`, `WARNING`, or `INFO`). This field is critical for developers to prioritize fixes—e.g., a `CRITICAL` error might indicate a missing regulatory deadline that could trigger a fine.
- A **`suggested_action`** field (a clear next step, e.g., "Increase your subscription tier" or "Verify your API key").

Here’s the **standardized error response payload**:

```json
{
  "status": "429",
  "code": "RATE_LIMIT_EXCEEDED",
  "message": "Your request quota for the 'RegCheckAlerts' endpoint has been exceeded.",
  "details": {
    "remaining_requests": 0,
    "reset_timestamp": "2024-05-20T14:30:00Z",
    "tier_limit": 1000,
    "current_period_usage": 1050
  },
  "compliance_impact": "WARNING",
  "suggested_action": "Upgrade to the Growth tier (10,000 requests/month) or wait until the next billing cycle to reset your limit."
}
```

For **developer-facing errors** (e.g., invalid API keys, malformed requests), the response includes a `suggested_action` with a direct link to documentation or support. For **user-facing errors** (e.g., missing evidence for an audit), the response is simplified for non-technical users, with a clear call-to-action like *"Upload your HIPAA training certificate to resolve this alert."*

---

****HTTP Status Code Mappings****
The API uses standard HTTP status codes with **compliance-specific extensions** where necessary. Below is the exhaustive mapping:

| **Status Code** | **Error Type**               | **Example Scenario**                                                                 | **Compliance Impact** | **Suggested Action**                                                                                     |
|-----------------|------------------------------|--------------------------------------------------------------------------------------|-----------------------|--------------------------------------------------------------------------------------------------------|
| `200 OK`        | Success                      | Alert created successfully with evidence captured.                                  | N/A                   | None.                                                                                                  |
| `201 Created`   | Resource created             | New compliance rule added to the user’s dashboard.                                  | N/A                   | None.                                                                                                  |
| `202 Accepted`  | Async task accepted           | Evidence upload queued for audit export.                                             | N/A                   | *"Your evidence is being processed. Check your dashboard in 5 minutes."*                              |
| `400 Bad Request`| Invalid input                | Missing `user_id` or `regulation_id` in the request payload.                        | `WARNING`             | *"Check your request payload for missing fields. [Link to API docs]."*                                  |
| `401 Unauthorized`| Invalid API key              | API key expired or revoked.                                                          | `CRITICAL`            | *"Your API key is invalid. [Generate a new key here]."*                                                 |
| `403 Forbidden`  | Insufficient permissions     | User lacks access to the requested regulation (e.g., trying to view a therapist’s HIPAA rule). | `CRITICAL` | *"You don’t have permission to view this regulation. Contact support to upgrade your tier."*          |
| `404 Not Found`  | Regulation/evidence missing  | Requested regulation ID or evidence file does not exist.                             | `CRITICAL`            | *"This regulation or evidence was not found. [Contact support]."*                                       |
| `429 Too Many Requests` | Rate limit exceeded      | User exceeded their monthly request quota (e.g., 1,050 requests in a Starter tier with a 1,000-limit). | `WARNING` | *"Increase your tier or wait until the next billing cycle."*                                           |
| `500 Internal Server Error` | Server failure          | Backend scraping pipeline failed to fetch a regulation update.                        | `CRITICAL`            | *"We’re experiencing technical difficulties. [Retry later] or [contact support]."*                     |
| `503 Service Unavailable` | Maintenance window       | Scheduled downtime for updates (e.g., GDPR guideline refresh).                      | `INFO`                | *"Our system is undergoing maintenance. Check back in 1 hour."*                                          |
| `408 Request Timeout` | Scraping pipeline timeout | The AI parser took too long to process a complex regulation (e.g., NYC zoning code). | `WARNING` | *"This regulation is complex. [Retry with a simpler query] or [contact support]."*                   |

---

****Rate Limiting Guardrails by Subscription Tier****
Rate limits are enforced **per API endpoint** and **per user account**, with strict differentiation between tiers to prevent abuse while ensuring fair access. Limits are **reset at midnight UTC** and apply to all HTTP methods (GET, POST, etc.). Below are the exact limits for each tier:

****Starter Tier ($7.99/month)****
- **General API Limits:**
  - **RegCheck Alerts Endpoint:** 1,000 requests/month.
  - **Evidence Capture Endpoint:** 500 requests/month.
  - **Audit Export Endpoint:** 10 requests/month.
- **Scraping Pipeline Limits:**
  - **Maximum concurrent regulations fetched:** 5 per minute.
  - **Maximum regulation complexity depth:** 3 levels (e.g., NYC contractor permits → subcategories → deadlines).
- **Enforcement:**
  - After 1,000 requests, the API returns a `429` with a `reset_timestamp` set for the next billing cycle.
  - Users exceeding limits **cannot create new alerts** until the limit resets, but existing alerts remain active.

****Growth Tier ($19.99/month)****
- **General API Limits:**
  - **RegCheck Alerts Endpoint:** 10,0

## End-to-End Integration Walkthrough

Here’s the **End-to-End Integration Walkthrough** for **WhileDirectProfitability’s RegCheck AI**, a step-by-step guide for developers to implement the core compliance tracking pipeline. This section assumes you’ve already set up the Firebase backend, Python scraping pipeline, and React frontend. Below is the **exact workflow** a developer would follow to connect a user’s workflow to RegCheck’s alert and evidence systems.

---

The integration begins with **user onboarding**, where a therapist in California signs up via the web app. The system immediately kicks off a **three-phase workflow**: (1) **Profile validation** to confirm regulatory scope, (2) **Rule-based scraping** to fetch applicable laws, and (3) **Alert dispatch** with evidence capture. Here’s how it works in practice:

****1. User Onboarding & Profile Validation****
When a user lands on the RegCheck dashboard, they’re prompted to select their **industry and location**. The frontend sends a `POST` request to `/api/v1/onboard` with their inputs. The backend validates the selection against a **predefined taxonomy** of regulated industries (e.g., "Healthcare," "Construction," "Finance") and locations (e.g., "California," "New York City"). If the combination is unrecognized (e.g., "Freelance DJ in Oregon"), the system returns a `400 Bad Request` with a suggestion to contact support. Example payload:

```json
{
  "user_id": "user_abc123",
  "industry": "healthcare",
  "location": "california",
  "business_type": "private_practice",
  "email": "user@example.com"
}
```

The backend then **enriches the user profile** by:
- Adding a `regulatory_scope` field (e.g., `["ca_bbs_license", "hipaa", "state_tax_deadlines"]`).
- Initializing a `compliance_status` object with `status: "pending"` and `last_checked: null`.
- Triggering a **background job** (via Firebase Cloud Functions) to scrape regulations.

---

****2. Rule-Based Scraping & Alert Generation****
The backend’s Python scraper runs on a **cron schedule (daily at 2 AM UTC)** and targets **public sources** like:
- **State-specific portals** (e.g., [CA BBS](https://www.bbs.ca.gov/) for therapists).
- **Federal guidelines** (e.g., [HIPAA](https://www.hhs.gov/hipaa/index.html)).
- **Local government sites** (e.g., NYC DOB for contractors).

The scraper uses **BeautifulSoup + Selenium** to parse:
- **Deadlines** (e.g., "License renewal due: 2024-12-31").
- **Actions required** (e.g., "Submit Form #XYZ").
- **Evidence requirements** (e.g., "Save a screenshot of your renewal confirmation").
- **Penalties** (e.g., "$500 fine for late renewal").

For example, scraping the CA BBS site yields:
```json
{
  "regulation": "ca_bbs_license_renewal",
  "deadline": "2024-12-31",
  "action": "Renew license via [link]",
  "evidence_needed": ["screenshot", "email_confirmation"],
  "penalty": "$500",
  "source": "https://www.bbs.ca.gov/"
}
```

The scraper then **enriches the user’s `compliance_status`** with the new regulation and marks it as `pending`. If the user already has a pending alert for this regulation (e.g., from a previous scrape), the system **updates the deadline** and **resets the evidence flag**.

---

****3. Alert Dispatch & User Interaction****
Once the scraper completes, the backend **triggers a Slack/email alert** via the `/api/v1/alerts/dispatch` endpoint. The payload includes:
- A **plain-language summary** (e.g., *"Your CA BBS license renewal is due in 30 days. Here’s how to renew: [link]."*).
- **Action buttons** (e.g., "Mark as completed," "Add evidence").
- **Evidence capture fields** (e.g., a form to upload a screenshot or email).

Example Slack message:
```
🚨 **RegCheck Alert: CA BBS License Renewal**
Your license for private practice in California expires on **Dec 31, 2024**.
✅ **Action:** Renew via [CA BBS Portal](https://www.bbs.ca.gov/)
📎 **Evidence:** Save your confirmation email here → [Upload Button]
⏰ **Deadline:** 30 days remaining
💰 **Penalty:** $500 for late renewal
```

When the user **marks the alert as completed**, the frontend sends a `PATCH` to `/api/v1/alerts/complete` with:
```json
{
  "alert_id": "alert_xyz789",
  "status": "completed",
  "evidence": {
    "type": "email",
    "url": "https://example.com/confirmation.pdf",
    "timestamp": "2024-07-01T12:00:00Z"
  }
}
```
The backend then:
1. Updates the user’s `compliance_status` to `status: "up_to_date"`.
2. **Auto-captures evidence** (e.g., saves the email URL in Firebase Storage).
3. **Archives the alert** but keeps it visible in the dashboard under "Completed."

---

****4. Audit-Ready Export****
During an audit, the user requests an **export** via `/api/v1/exports/audit`. The backend:
1. **Aggregates all compliance evidence** (e.g., license renewals, training certificates, emails) into a single PDF.
2. **Includes metadata** like:
   - Regulation name (e.g., "CA BBS License").
   - Deadline.
   - Evidence type (e.g., "Email confirmation").
   - Timestamp.
3. **Generates a timestamped URL** (e.g., `https://regcheck.ai/exports/user_abc123/audit_20240701.pdf`).

Example PDF structure:
```
---
RegCheck AI Audit Export | user@example.com
---
**Regulation:** CA BBS License Renewal
**Deadline:** Dec 31, 2024
**Status:** Up to Date
**Evidence:**
  - Email Confirmation: [Link]
  - Screenshot: [Image]
---
```

The PDF is **watermarked** with the user’s email and a "Do not edit" notice. The backend logs the export in Firebase with:
```json
{
  "user_id": "user_abc123",
  "export
