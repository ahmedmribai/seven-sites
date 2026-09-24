# InflactASaas — Integration Guide

## 1. System Overview & Architecture

Inflact Safe‑Mode is built around a **dual‑engine architecture** that guarantees every growth action either stays inside the Instagram Graph API’s whitelist or is executed by a vetted human operator under strict supervision. The two engines run side‑by‑side, share a common state store, and feed a unified risk‑monitoring layer that can pause the whole pipeline the instant a policy breach is detected.  

When a user enables **Safe‑Mode** in the dashboard, the front‑end immediately records the request in a **Growth Intent Log** (GIL). Each intent contains the Instagram Business Account ID, the desired action type (DM, comment‑moderation, story‑repost, follow, like, comment), the target object ID, a timestamp, and the user‑defined daily cap. The GIL is persisted in a PostgreSQL table with a unique UUID, which becomes the single source of truth for both engines.  

The **Compliance Engine** watches the GIL for intents that map to Graph‑API‑allowed verbs:  

* **DM reply** – `POST /{ig-user-id}/messages`  
* **Comment moderation** – `POST /{ig-comment-id}/hide` / `POST /{ig-comment-id}/unhide`  
* **Story repost** – `POST /{ig-user-id}/stories`  

For each matching row the engine builds a signed request using the user’s OAuth access token, injects the required `X‑Instagram‑API‑Version` header, and forwards the call to the Graph endpoint. Successful responses are written back to the GIL with a status of **COMPLETED** and the raw JSON payload for audit.  

All other growth actions—**follow, like, comment**—are **not** exposed by the Graph API. Those rows are instantly re‑routed to the **Human‑in‑the‑Loop (HITL) Queue**. The queue is a lightweight Redis‑backed worklist (`RPUSH`/`LPOP`) that guarantees FIFO ordering while allowing multiple workers to pull tasks concurrently. Each task payload includes the same fields as the GIL entry plus a `priority` flag derived from the user’s daily cap utilization (high priority when the user is close to their limit).  

A pool of **Growth Operators**—freelance Instagram power users vetted through a two‑step process (identity verification + a 30‑minute live test on a shared Android device farm)—run a Node.js worker script on a secure VM. The script pulls the next task, logs into the shared device via Android Debug Bridge (ADB) using the operator’s personal credentials, and executes the action through the Instagram mobile UI. The worker then captures a screenshot, the device‑fingerprint hash, and the HTTP response from Instagram’s private endpoint (if any). All artefacts are posted back to the central API (`POST /api/v1/hitl/complete`) where they are stored alongside the original GIL entry.  

Because every manual action is recorded, the system can compute a **Risk Score** in real time. The score aggregates three signals:  

1. **API‑level violations** – any non‑2xx Graph response (e.g., `429 Too Many Requests`, `400 Bad Request` with “action not permitted”) adds 30 points.  
2. **Device‑fingerprint anomalies** – if the operator’s device hash deviates from the last 10 actions for that account, add 20 points.  
3. **Rate‑limit proximity** – the Graph API returns `X‑RateLimit‑Remaining`; if the remaining quota falls below 10 % of the daily allowance, add 10 points.  

The risk‑monitoring service polls the GIL every 5 seconds, recalculates the cumulative score per account, and compares it against a configurable threshold (default **70 points**). When the threshold is crossed, the service emits a **Pause Event** to both engines: the Compliance Engine stops issuing new Graph calls, and the HITL workers receive a `SIGUSR2` that forces them to finish the current task then idle. Simultaneously, an email and SMS alert are dispatched using SendGrid and Twilio, respectively, with the exact wording the user can copy into a support ticket:

> “Your Inflact Safe‑Mode session has been automatically paused because the system detected a risk score of 78 points (rate‑limit 8 % remaining, recent device‑hash mismatch). No further actions will be taken until you review the dashboard and confirm “Resume”. If you need immediate assistance, reply to this message with the word **UNPAUSE**.”

The **State Synchronizer** bridges the two engines. Whenever a HITL task finishes, the synchronizer updates the GIL entry’s status, decrements the user’s daily cap counter, and pushes a lightweight event (`growth_action_completed`) onto a Kafka topic. The Compliance Engine subscribes to this topic to stay aware of total actions per account, ensuring that the combined volume never exceeds the user‑defined caps. This cross‑engine awareness is what allows Inflact to promise “no more than 500 actions per day” while still delivering high‑volume growth through human operators.  

All components are containerised with Docker and orchestrated by Kubernetes (v1.28). The deployment diagram looks like this:

* **Frontend (React)** → **API Gateway (NGINX)** → **Auth Service (Node/Passport‑OAuth2)** → **Growth Service (Node)** → *splits into* **Compliance Engine** and **HITL Dispatcher**  
* **Compliance Engine** → **Graph API** (Meta)  
* **HITL Dispatcher** → **Redis Queue** → **Worker Pods** (Android VM images) → **Device Farm** (Google Cloud GPU‑enabled VMs)  
* **Risk Monitor** → **PostgreSQL** (GIL) + **Kafka** (events) + **Alert Service** (SendGrid/Twilio)  

A concrete end‑to‑end flow illustrates the architecture in action. Assume a user, **@brandcoach**, wants to “auto‑like” 150 posts from the hashtag #digitalmarketing, but has set a daily cap of 200 actions and enabled Safe‑Mode. The dashboard sends the following JSON to the Growth Service:

```json
{
  "request_id": "c7f9a2e4-3b1d-4f6a-9d2e-5b7c9e1a2d3f",
  "account_id": "17841405822304914",
  "action": "like",
  "targets": [
    "178956956

## 2. Authentication & OAuth Integration

Instagram’s OAuth 2.0 flow is the gateway to secure, compliant access for Inflact’s **Safe-Mode**—but it requires precision to avoid rate limits, token expiry, and the risk of revoked permissions. Below is the exact implementation for connecting Instagram Business Accounts, including token handling, refresh logic, and error recovery, all tailored to Inflact’s **$49/month Safe-Mode tier** where compliance and reliability are non-negotiable.

---

****Step 1: OAuth 2.0 Flow for Instagram Business Accounts****
Instagram’s OAuth 2.0 flow is server-side with a **public redirect URI** (`https://inflact.com/oauth/callback`) and **client credentials** (client ID + secret). The flow must handle:
- **Authorization Code Grant** (for user consent)
- **Token refresh** (every 60 days, per Meta’s policy)
- **Business Account validation** (non-public profiles, verified accounts only)

****1.1 Client Setup & Redirect URI****
Register your app in the [Meta Developer Portal](https://developers.facebook.com/) under **Instagram Graph API v18.0**. Key settings:
```json
{
  "client_name": "Inflact Safe-Mode",
  "redirect_uris": ["https://inflact.com/oauth/callback"],
  "valid_redirect_uris": ["https://inflact.com/oauth/callback"],
  "platform": "web",
  "app_domains": ["inflact.com"],
  "default_audience": "public",
  "instagram_basic_access": true,
  "instagram_manage_comments": true,
  "instagram_manage_messages": true
}
```
**Critical Note:** Instagram **does not** support OAuth for follower/like/comment actions—only **Business Account** access. Enforce this in your frontend:
```javascript
// Frontend validation (React)
const validateInstagramBusinessAccount = async (accessToken) => {
  const response = await fetch('https://graph.instagram.com/me?fields=id,account_type', {
    headers: { 'Authorization': `Bearer ${accessToken}` }
  });
  const data = await response.json();
  if (data.account_type !== 'business') {
    throw new Error('Only Instagram Business Accounts are supported.');
  }
};
```

****1.2 Authorization Request****
Users initiate OAuth via a **pre-authorized URL** with scopes and redirect parameters:
```plaintext
https://api.instagram.com/oauth/authorize?
  client_id=YOUR_CLIENT_ID
  &redirect_uri=https://inflact.com/oauth/callback
  &response_type=code
  &scope=user_profile,user_media,instagram_basic,instagram_manage_comments,instagram_manage_messages
  &state=RANDOM_STRING_128_CHARS
```
**Scopes Breakdown:**
- `user_profile`: Basic profile data (required for Business Account validation).
- `user_media`: Read/write access to posts/stories (for reposting).
- `instagram_basic`: Permits DM replies and comment moderation.
- **Critical Exclusion:** `instagram_content_publish` (banned by Meta for automation).

****1.3 Token Exchange & Storage****
After user approval, Instagram redirects to your callback with a **short-lived authorization code**. Exchange it for tokens:
```javascript
// Backend (Node.js/Express)
app.post('/oauth/callback', async (req, res) => {
  const { code, state } = req.query;
  const { CLIENT_ID, CLIENT_SECRET } = process.env;

  const tokenResponse = await fetch('https://graph.instagram.com/oauth/access_token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      grant_type: 'authorization_code',
      code,
      redirect_uri: 'https://inflact.com/oauth/callback',
      state
    })
  });

  const { access_token, expires_in } = await tokenResponse.json();
  const expiresAt = new Date().getTime() + (expires_in * 1000 - 300000); // Buffer 5 mins

  // Store in Redis (TTL = expires_in - 300s)
  await redis.setex(`instagram_token:${req.user.id}`, expires_in - 300, JSON.stringify({
    access_token,
    expiresAt,
    refresh_token: tokenResponse.json().refresh_token // Only if provided
  }));
});
```

****1.4 Token Refresh Logic****
Instagram access tokens expire after **60 days**. Implement a **background job** (e.g., BullMQ) to refresh tokens silently:
```javascript
// Background job (refresh tokens every 55 days)
const refreshTokenQueue = new Queue('instagram_token_refresh', redis);

refreshTokenQueue.process(async (job) => {
  const { userId, refreshToken } = job.data;
  const storedToken = await redis.get(`instagram_token:${userId}`);

  if (!storedToken) return;

  const { access_token, expiresAt } = JSON.parse(storedToken);
  if (Date.now() < expiresAt - 86400000) return; // Skip if >1 day left

  const refreshResponse = await fetch('https://graph.instagram.com/oauth/access_token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      grant_type: 'refresh_token',
      refresh_token
    })
  });

  const newTokens = await refreshResponse.json();
  await redis.setex(`instagram_token:${userId}`, newTokens.expires_in - 300, JSON.stringify({
    ...newTokens,
    expiresAt: new Date().getTime() + (newTokens.expires_in * 1000 - 300000)
  }));
});
```

---

****Step 2: Handling Rate Limits & Token Revocation****
Instagram enforces **strict rate limits** (e.g., 500 requests/hour per token). Violations trigger **429 errors** or token revocation. Mitigate this with:

****2.1 Exponential Backoff for 429 Errors****
Wrap API calls in a retry mechanism:
```javascript
const callInstagramAPI = async (endpoint, params, accessToken) => {
  let retries = 0;
  const maxRetries = 5;

  while (retries < maxRetries) {
    try {
      const response = await fetch(`https://graph.instagram.com${endpoint}`, {
        headers: { 'Authorization': `Bearer ${accessToken}` }
      });

      if (response.status === 429) {
        const retryAfter = response.headers.get('Retry-After')

## 3. Compliance-First API Endpoints

Instagram’s Graph API is a strict but structured playground for automation—if you know how to play by its rules. The key to building a **compliance-first** growth engine lies in leveraging the API’s officially permitted endpoints while avoiding the blacklisted actions (e.g., auto-follow, auto-like) that trigger bans. Below is the exact specification for the endpoints you can use today, along with request/response payloads, authentication flows, and rate-limit handling. These are the only actions you should automate directly through the API to stay within Instagram’s terms of service.

---

****1. Authentication: OAuth 2.0 for Instagram Graph API****
To interact with Instagram’s Graph API, you must first obtain an **access token** via OAuth 2.0. This token grants permissions scoped to your app’s needs. Below is the exact flow:

****Step 1: Register Your App****
1. Go to the [Meta Developer Portal](https://developers.facebook.com/) and create an app.
2. Under **Products**, select **Instagram Graph API**.
3. Configure the following:
   - **Valid OAuth Redirect URIs**: `https://yourdomain.com/oauth/callback`
   - **Instagram Graph API Permissions**: Request at least these scopes:
     - `instagram_basic`
     - `instagram_content_publish` (for reposting stories)
     - `instagram_manage_comments` (for moderation)
     - `instagram_manage_inbox` (for DM replies)
   - **Website URL**: Your domain (required for verification).

****Step 2: Generate an OAuth URL****
Use this template to redirect users to Instagram for authentication:
```plaintext
https://api.instagram.com/oauth/authorize?
  client_id={YOUR_APP_ID}
  &redirect_uri={YOUR_REDIRECT_URI}
  &response_type=code
  &scope=instagram_basic%20instagram_content_publish%20instagram_manage_comments%20instagram_manage_inbox
  &state={CSRF_TOKEN}
```
Replace `{YOUR_APP_ID}`, `{YOUR_REDIRECT_URI}`, and `{CSRF_TOKEN}` with your app’s details. The `state` parameter is critical for CSRF protection.

****Step 3: Exchange Code for Access Token****
After the user grants permissions, Instagram redirects to your `redirect_uri` with a `code` parameter. Exchange this for an **access token** via a POST request:

```http
POST /v20.0/oauth/access_token
Host: graph.facebook.com
Content-Type: application/x-www-form-urlencoded

client_id={YOUR_APP_ID}
&client_secret={YOUR_APP_SECRET}
&grant_type=authorization_code
&redirect_uri={YOUR_REDIRECT_URI}
&code={AUTH_CODE_FROM_REDIRECT}
```
**Response (success):**
```json
{
  "access_token": "IGQVJY...",
  "expires_in": 604800,
  "user_id": "123456789"
}
```
- **`access_token`**: Your primary key for API calls. Store this securely.
- **`expires_in`**: Token validity (24 hours by default; Instagram may shorten this).
- **`user_id`**: The Instagram user’s ID (e.g., `123456789`).

****Step 4: Refresh the Token****
Tokens expire after 24 hours. To refresh:
```http
POST /v20.0/oauth/access_token
Host: graph.facebook.com
Content-Type: application/x-www-form-urlencoded

client_id={YOUR_APP_ID}
&client_secret={YOUR_APP_SECRET}
&grant_type=fb_exchange_token
&fb_exchange_token={EXPIRED_TOKEN}
```
**Response:**
```json
{
  "access_token": "NEW_IGQVJY..."
}
```

---

****2. Compliance-First API Endpoints****
These are the **only** actions you can automate directly through the Graph API without risking a ban. All others (e.g., `follow`, `like`, `comment`) require a human-in-the-loop (HITL) approach.

****Endpoint 1: Reply to Direct Messages (DMs)****
Instagram allows automated replies to DMs **only** if sent within 24 hours of the original message. This is the only "growth-adjacent" action permitted via the API.

**Request:**
```http
POST /v20.0/me/messages
Host: graph.facebook.com
Authorization: Bearer IGQVJY...
Content-Type: application/json

{
  "recipient_id": "123456789",
  "message_text": "Thanks for reaching out! Here’s a link to our latest post: https://instagram.com/p/abc123",
  "thread_id": "THREAD_ID_FROM_PREVIOUS_REPLY"
}
```
- **`recipient_id`**: The user’s Instagram ID (e.g., `123456789`).
- **`message_text`**: Your reply (max 2200 characters).
- **`thread_id`**: Required if replying to an existing thread. Fetch this via:
  ```http
  GET /v20.0/me/messages?fields=thread_id
  Host: graph.facebook.com
  Authorization: Bearer IGQVJY...
  ```

**Response (success):**
```json
{
  "id": "MESSAGE_ID",
  "thread_id": "THREAD_ID",
  "sender_id": "123456789",
  "text": "Thanks for reaching out!"
}
```

**Error Handling:**
- **`(OAuthException)` Code 190**: Token expired or invalid. Refresh the token.
- **`(OAuthException)` Code 100`: Rate limit exceeded. Wait 60 seconds and retry.

---

****Endpoint 2: Moderate Comments****
You can **delete** or **hide** comments programmatically. This is useful for spam control.

**Request (delete comment):**
```http
DELETE /v20.0/{COMMENT_ID}
Host: graph.facebook.com
Authorization: Bearer IGQVJY...
```
- **`{COMMENT_ID}`**: The ID of the comment to delete (e.g., `123456789_10158_123456789`).

**Response (success):**
```json
{
  "id": "123456789_10158_123456789"
}
```

**Request (hide comment):**
```http
POST /v20.0/{COMMENT_ID}/hide
Host: graph.facebook.com
Authorization: Bearer IGQVJY...
```

---

****Endpoint 3: Repost Stories****
You can **repost** a story to

## 4. Human-in-the-Loop (HITL) Execution Engine

The **Human-in-the-Loop (HITL) Execution Engine** is the backbone of Inflact’s “Safe-Mode” strategy, bridging the gap between Instagram’s restrictive Graph API and the high-volume growth actions users demand. Since the official API only permits DM replies, comment moderation, and story reposts—none of which drive meaningful follower growth—this engine routes all other actions (auto-follow, auto-like, auto-comment) to vetted freelance operators who execute them manually on a shared device farm. The system ensures compliance while delivering the volume users expect, but its success hinges on precise task distribution, worker assignment logic, and device-farm orchestration. Below is the exact protocol, with real-world parameters and examples.

---

The task distribution protocol operates on a **first-come, first-served queue with priority tiers**, ensuring fairness while optimizing for speed. When a user initiates a growth action (e.g., “follow 50 accounts”), the system pushes it into a **priority queue** based on:
- **Action type** (follows are higher priority than likes, which are higher than comments).
- **User tier** (paid subscribers get a 10% faster processing window than free users).
- **Risk score** (actions flagged by the real-time monitoring system are deprioritized).

Here’s how it works in practice:

```json
{
  "task": {
    "action": "follow",
    "target_accounts": ["@account1", "@account2", "@account3"],
    "user_id": "user_12345",
    "priority": "high",
    "risk_score": 0.3,
    "queue_position": 42
  }
}
```

The queue is processed by a **dedicated Node.js worker pool** (scalable to 50 concurrent tasks) that assigns tasks to freelancers via a **Trello-like Kanban board** with these columns:
- **Backlog** (new tasks, sorted by priority).
- **Assigned** (tasks picked up by a freelancer).
- **In Progress** (tasks being executed).
- **Completed** (tasks verified by the system).
- **Failed** (tasks that triggered a ban risk).

Freelancers are **pre-vetted contractors** with a 98% success rate (verified via Instagram account age, engagement history, and device fingerprint consistency). They use a **shared Android device farm** (100+ devices, rotated every 24 hours to avoid fingerprint detection) managed by the Inflact backend. Each device is pre-configured with:
- **Instagram app version 247.0.0.29.105** (latest stable).
- **Geolocation spoofing** (randomized within user’s country).
- **Session tokens** (rotated every 72 hours to mimic human behavior).

When a freelancer picks up a task, they receive a **real-time notification** with:
```json
{
  "instruction": "Follow these accounts (do not like/comment yet):",
  "accounts": ["@account1", "@account2"],
  "device_id": "android_12345",
  "session_token": "abc123xyz",
  "timeout": 300, // 5 minutes
  "risk_threshold": 0.7 // If risk score exceeds this, pause and notify
}
```

The freelancer logs into the shared device via a **secure VPN tunnel** (encrypted with AES-256) and executes the action. The system **verifies completion** by:
1. Checking Instagram’s Graph API for the action’s metadata (e.g., follow timestamp).
2. Cross-referencing with the freelancer’s device fingerprint.
3. Validating no duplicate actions were performed.

If verification fails (e.g., the follow wasn’t recorded), the task is **requeued with a 2x penalty delay**.

---

Worker assignment logic uses a **weighted random selection** algorithm to distribute tasks evenly across freelancers while accounting for:
- **Task volume** (no freelancer handles >20 tasks/hour).
- **Success rate** (top 20% of freelancers get 60% of tasks).
- **Geographic proximity** (tasks are routed to freelancers in the same country as the target account).

Here’s the assignment formula:
```python
def assign_task(task, freelancers):
    weighted_scores = []
    for freelancer in freelancers:
        score = (
            freelancer.success_rate * 0.7 +
            (1 - freelancer.task_volume/20) * 0.2 +
            (1 if freelancer.country == task.target_country else 0.5) * 0.1
        )
        weighted_scores.append((freelancer.id, score))
    return random.choices([f[0] for f in weighted_scores], weights=[f[1] for f in weighted_scores])[0]
```

This ensures no single freelancer becomes a bottleneck while maintaining compliance.

---

Device-farm routing mechanics are designed to **mimic human behavior** and avoid detection. The system:
1. **Rotates devices every 24 hours** to prevent fingerprinting.
2. **Randomizes session tokens** every 72 hours (simulating account logouts).
3. **Injects delays** between actions (1–3 seconds) to avoid rate-limiting.
4. **Spoofs geolocation** within a 50km radius of the target account’s location.

For example, if a user requests 100 follows, the system:
- Splits them into **10 batches of 10** (to avoid bulk detection).
- Assigns each batch to a different freelancer.
- Routes each batch to a **random device** from the farm.
- Adds a **15-second delay** between batches.

Here’s a sample routing payload:
```json
{
  "batch": 1,
  "accounts": ["@account1", "@account2", "@account3"],
  "device_rotation": {
    "current_device": "android_12345",
    "next_device": "android_67890",
    "rotation_time": 86400 // 24 hours
  },
  "geolocation": {
    "latitude": 37.7749,
    "longitude": -122.4194,
    "radius": 50000 // 50km
  }
}
```

---

Error handling is critical to prevent bans. If a freelancer fails to complete a task (e.g., due to Instagram’s restrictions), the system:
1. **Auto-pauses** further actions for the user (with a 1-hour cooldown).
2. **Triggers a risk alert** in the dashboard:
   ```json
   {
     "alert": {
       "type": "high_risk",
       "message": "Task failed: Account @account1 may have been restricted.",
       "recommendation": "Disable Safe-Mode for 24 hours or contact

## 5. Real-Time Risk Monitoring & Telemetry

Inflact’s real-time risk monitoring system is the neural core of **Safe-Mode**, designed to detect and neutralize threats before they trigger Instagram’s anti-spam algorithms. It operates on three parallel tracks: **API telemetry**, **behavioral fingerprinting**, and **predictive risk scoring**, with automated circuit-breaker logic that pauses actions at the first sign of instability. Below is the exact implementation, including rate-limit parsing, risk-score formulas, and pause triggers—all built to integrate seamlessly with the Inflact dashboard and HITL queue.

---

The system begins with **rate-limit header parsing**, where every API request’s response must be inspected for `X-RateLimit-*` headers. Instagram’s Graph API enforces two critical limits: **user-level** (e.g., `X-RateLimit-Limit: 2000` for DMs per day) and **IP-level** (e.g., `X-RateLimit-Limit: 50` for comment moderation). The Inflact engine logs these headers in real-time and calculates **remaining capacity** using this formula:

```javascript
const remainingCapacity = parseInt(response.headers['x-ratelimit-remaining']);
const resetTime = new Date(response.headers['x-ratelimit-reset'] * 1000);
const currentTime = Date.now();
const secondsUntilReset = Math.ceil((resetTime - currentTime) / 1000);
```

For HITL actions (e.g., auto-follows executed by freelancers), we introduce a **device-fingerprint risk score**, computed from:
- **Geolocation variance** (if the device’s IP jumps >50km from the user’s account’s last login location).
- **Request frequency** (if >3 actions are queued within a 10-minute window).
- **Response latency** (if HITL execution takes >120 seconds, flag as potential bot detection).

The **combined risk score** (0–100) is calculated as:
```
riskScore =
  (rateLimitViolationWeight * rateLimitViolationScore) +
  (fingerprintVarianceWeight * fingerprintVarianceScore) +
  (executionLatencyWeight * latencyPenalty)
```
Where weights default to:
```javascript
const weights = {
  rateLimitViolation: 0.4,
  fingerprintVariance: 0.35,
  executionLatency: 0.25
};
```

**Circuit-breaker triggers** activate when:
- **Risk score exceeds 70** → Pause all API and HITL actions for 15 minutes.
- **Three consecutive rate-limit violations** → Pause for 24 hours and notify the user via email/SMS with a link to the risk dashboard.
- **Device-fingerprint score >80** → Route the HITL task to a secondary operator pool (pre-approved, low-risk freelancers).

For example, if a user’s account suddenly receives a `429 Too Many Requests` response for comment moderation, the system logs:
```json
{
  "event": "rate_limit_violation",
  "action": "comment_moderation",
  "limit": 50,
  "remaining": 0,
  "reset": "2024-06-15T03:45:00Z",
  "risk_score": 85,
  "action": "PAUSE_ALL"
}
```
This triggers an immediate pause and a notification:
> **⚠️ Risk Alert: Your account has hit Instagram’s comment moderation limit. All actions paused for 15 minutes. Check [Inflact Dashboard](https://app.inflact.com/risk) for details.**

To integrate this into your backend, use the following **Node.js snippet** for parsing headers and triggering pauses:

```javascript
const axios = require('axios');
const { pauseActions, logRiskEvent } = require('./riskMonitor');

async function sendInstagramRequest(config) {
  try {
    const response = await axios(config);
    const rateLimitHeaders = {
      remaining: response.headers['x-ratelimit-remaining'],
      limit: response.headers['x-ratelimit-limit'],
      reset: response.headers['x-ratelimit-reset']
    };

    // Calculate risk score (simplified example)
    const riskScore = calculateRiskScore(rateLimitHeaders, config.data);

    if (riskScore > 70) {
      await pauseActions(config.userId, 'rate_limit_exceeded');
      await logRiskEvent(config.userId, {
        type: 'rate_limit_violation',
        score: riskScore,
        action: config.data.action
      });
    }
    return response.data;
  } catch (error) {
    if (error.response?.status === 429) {
      await pauseActions(config.userId, 'too_many_requests');
      await logRiskEvent(config.userId, {
        type: '429_error',
        score: 100,
        action: config.data.action
      });
    }
    throw error;
  }
}
```

For HITL tasks, the risk score is dynamically updated via WebSocket streams from the freelancer device farm. If a task’s execution latency exceeds 120 seconds, the system auto-requeues it to a different operator and increments the risk score by 15 points. This ensures no single point of failure (e.g., a slow freelancer) derails the entire system.

---
**Key integration notes:**
- **Rate-limit headers** must be parsed on every API response. Use `axios.interceptors.response` to log them automatically.
- **Device-fingerprint checks** require IP geolocation (e.g., via `ip-api.com`) and historical login data stored in Inflact’s database.
- **Circuit-breaker logic** should be implemented as a **Redis pub/sub** system to coordinate pauses across microservices.
- **User notifications** must include a **risk dashboard link** (e.g., `/risk?accountId=12345`) with actionable insights like:
  - *"Your last 5 actions had a 78% risk score due to rapid HITL execution. Slow down or enable Safe-Mode."*
  - *"Your IP has been flagged for geolocation variance. Update your login location in Settings."*

This system ensures **zero false positives** while maintaining **real-time responsiveness**. For example, if a user’s account suddenly receives a `403 Forbidden` (ban risk), the system logs:
```json
{
  "event": "account_restriction",
  "details": {
    "error_code": "403",
    "action": "comment_like",
    "timestamp": "2024-06-14T18:30:00Z"
  },
  "risk_score": 100,
  "action": "PAUSE_ALL_AND_NOTIFY"
}
```
Triggering an immediate pause and a **priority support ticket** for the user’s account recovery SLA.

## 6. Error Handling & Rate Limit Management

Instagram’s Graph API is a double-edged sword for automation tools like InflactASaaS: it provides a *legal* foundation for certain actions (DM replies, comment moderation, story reposts) but explicitly prohibits others (auto-follow, auto-like, auto-comment). When the system violates these rules, Instagram’s enforcement algorithms trigger a cascade of errors, rate limits, and eventual bans. Your job is to anticipate these failures, handle them gracefully, and recover without losing user trust or revenue. Below is a **practical, actionable framework** for error handling and rate limit management—one that balances strict compliance with the flexibility users demand.

---

****Error Codes, Responses, and Their Meaning****
Instagram’s Graph API communicates errors through HTTP status codes and custom error objects. The most critical ones fall into three categories: **authentication failures**, **rate limit violations**, and **policy violations**. Here’s how to interpret them and respond:

****Authentication Errors (4xx)****
These occur when OAuth tokens expire, permissions are insufficient, or the connection is invalid. The API returns a `401 Unauthorized` or `403 Forbidden` with a `error` field in the response body. Example:

```json
{
  "error": {
    "message": "An active access token must be used to query information about the current user.",
    "type": "OAuthException",
    "code": 190,
    "error_subcode": 460,
    "fbtrace_id": "..."  // Debugging ID
  }
}
```
**Immediate Actions:**
- **Exponential Backoff:** If the error is `190` (invalid token), trigger a silent OAuth refresh. Use a backoff algorithm like this:
  ```javascript
  const retryDelay = Math.min(2 ** attempt, 60000); // Max 60s delay
  await new Promise(resolve => setTimeout(resolve, retryDelay));
  ```
- **User Notification:** If the token is manually revoked (e.g., user logs out), send a **webhook alert** to the dashboard with this payload:
  ```json
  {
    "event": "auth_failure",
    "timestamp": "2024-05-20T14:30:00Z",
    "error_code": 190,
    "recommended_action": "reconnect_account",
    "severity": "medium"
  }
  ```
- **Fallback Mechanism:** If OAuth fails three times in a row, queue the failed action for **HITL execution** (see Section 4) with a note: *“Auto-follow failed due to API restrictions; manual review required.”*

---

****Rate Limit Violations (429)****
Instagram enforces strict rate limits per endpoint. Violations return a `429 Too Many Requests` with headers like:
```
X-RateLimit-Limit: 5000
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1716254400
```
**Strategies:**
1. **Dynamic Throttling:** Adjust request intervals using the `X-RateLimit-Reset` header. Example:
   ```python
   def wait_until_ready(reset_timestamp):
       delay = (reset_timestamp - time.time()) * 1.1  # 10% buffer
       if delay > 0:
           time.sleep(delay)
   ```
2. **Priority Queuing:** For high-volume actions (e.g., 500 DM replies), split them into chunks of 100–200 requests with delays between batches. Log each batch’s success/failure to a telemetry table:
   ```sql
   INSERT INTO rate_limit_events
   (endpoint, attempts, success_rate, timestamp)
   VALUES ('graphql', 3, 0.75, NOW());
   ```
3. **User Alerts:** If a user exceeds limits repeatedly, send a **proactive email** with this template:
   > *Subject:* Your Instagram Actions Are Being Throttled
   > *Body:*
   >   We detected that your account hit Instagram’s rate limits 3x this week. To avoid disruptions:
   >   - Reduce daily actions by 30% (current cap: 500 actions/day).
   >   - Enable **Safe-Mode Auto-Pause** in your dashboard to auto-throttle during spikes.
   >   *Need help?* Reply to this email or visit [support link].

---

****Policy Violations (4xx with `error_subcode`)****
These are the most dangerous. Instagram’s `400 Bad Request` or `403 Forbidden` errors often include `error_subcode` values like `460` (invalid token), `480` (unauthorized business use), or **`500001`** (suspicious activity). Example:
```json
{
  "error": {
    "message": "This endpoint requires the 'pages_manage_posts' permission or an app review.",
    "type": "OAuthException",
    "code": 500001,
    "error_subcode": 500001,
    "fbtrace_id": "..."
  }
}
```
**Critical Actions:**
- **Immediate Pause:** Halt all automation for the account. Update the dashboard’s “risk score” (see Section 5) to **100/100** and notify the user via:
  ```json
  {
    "event": "policy_violation",
    "account_id": "12345",
    "subcode": 500001,
    "recommended_action": "manual_review_required",
    "severity": "critical"
  }
  ```
- **HITL Escalation:** Route all pending actions to your freelance operator pool with a **priority flag** and this note:
  > *“Instagram flagged this account for suspicious activity. Execute manually using a fresh device (Android 12+, no VPN).”*
- **Account Recovery SLA:** If the ban persists after 48 hours, trigger the **2-month service credit** (as per your MVP spec) and open a support ticket with this workflow:
  1. **Step 1:** Send the user a **DM template** to Instagram Support:
     > *“Hi Instagram Team,
     >   My account (ID: [USER_ID]) was flagged on [DATE] while using [InflactASaaS]. I’ve disabled automation and will monitor for 7 days. Please review my activity logs at [LINK].
     >   — [USER_NAME]”*
  2. **Step 2:** Monitor the user’s account for **shadow-ban signals** (e.g., likes/comments disappearing). If confirmed, escalate to your **dedicated recovery team** (3rd-party specialists).

---

****Automated Alert Webhook Payloads**

## 7. End-to-End Integration Walkthrough

Here’s the complete, actionable **End-to-End Integration Walkthrough** for Inflact’s Safe-Mode MVP, designed for developers to deploy immediately:

---

The integration begins with a user onboarding flow that enforces compliance from the first click. When a user lands on the Inflact dashboard and selects **"Connect Instagram Account"**, they’re redirected to Instagram’s OAuth flow with pre-configured permissions. The exact OAuth request payload is:

```http
POST https://api.instagram.com/oauth/authorize
Headers:
  Content-Type: application/x-www-form-urlencoded
Body:
  client_id=YOUR_INFLACT_CLIENT_ID
  redirect_uri=https://yourdomain.com/oauth/callback
  response_type=code
  scope=instagram_basic,instagram_content_publish,instagram_graph_user_content,instagram_graph_user_profile
  state=RANDOM_STRING_16_CHARS
```

After approval, Instagram returns a `code` in the URL fragment. Your backend immediately exchanges this for an access token via:

```http
POST https://api.instagram.com/oauth/access_token
Headers:
  Content-Type: application/x-www-form-urlencoded
Body:
  client_id=YOUR_INFLACT_CLIENT_ID
  client_secret=YOUR_INFLACT_CLIENT_SECRET
  grant_type=authorization_code
  redirect_uri=https://yourdomain.com/oauth/callback
  code=USER_PROVIDED_CODE
```

The response includes a `user_id` and `access_token` (valid for 60 days). Store this securely in Inflact’s database under the user’s profile, along with a `refresh_token` for future token renewal. The user then toggles **"Safe-Mode"** in the dashboard, which triggers the compliance-first engine. For example, if they select **"Auto-Reply to DMs"**, Inflact’s backend polls the Instagram Graph API every 15 minutes for new messages using:

```http
GET https://graph.instagram.com/{user_id}/messages?access_token={ACCESS_TOKEN}&fields=id,thread_id,text,from,created_time
Headers:
  Authorization: Bearer {ACCESS_TOKEN}
  Instagram-API-Version: v13.0
```

If a message arrives, Inflact’s compliance engine checks if the sender is a verified business account (via `is_verified` flag) before replying. The reply payload is:

```http
POST https://graph.instagram.com/{thread_id}/messages
Headers:
  Authorization: Bearer {ACCESS_TOKEN}
  Instagram-API-Version: v13.0
  Content-Type: application/json
Body:
{
  "text": "Thanks for reaching out! Here’s our latest product: [LINK]. Safe-Mode ensures we only reply to verified accounts."
}
```

For actions outside the Graph API (e.g., auto-follow), Inflact routes the request to the HITL queue. The frontend sends a payload like this to the HITL API:

```http
POST https://api.inflact.com/hitl/queue
Headers:
  Authorization: Bearer {USER_JWT_TOKEN}
  Content-Type: application/json
Body:
{
  "user_id": "USER_ID",
  "action": "follow",
  "target_account": "TARGET_ACCOUNT_HANDLE",
  "device_pool": "us_east_1",
  "priority": "high"
}
```

The HITL engine assigns this task to a vetted operator on a shared Android device (e.g., Pixel 6 with a fingerprint profile matching Instagram’s device fingerprint rules). The operator receives a push notification with the task details and a 30-second window to execute it. If they fail (e.g., Instagram blocks the action), the task is escalated to Inflact’s support team, who manually reviews the account’s risk score (see below).

Real-time risk monitoring begins immediately after Safe-Mode activation. Inflact’s backend polls Instagram’s API rate-limit headers every 5 seconds using:

```http
HEAD https://graph.instagram.com/{user_id}/?access_token={ACCESS_TOKEN}
Headers:
  Authorization: Bearer {ACCESS_TOKEN}
  Instagram-API-Version: v13.0
```

The `X-RateLimit-Remaining` header is logged, and if it drops below 5, Inflact auto-pauses all actions and triggers this alert:

```javascript
// Pseudocode for alert logic
if (rateLimitRemaining < 5) {
  sendSMS(user.phone, "Inflact Alert: Your Instagram account is approaching rate limits. Safe-Mode paused actions.");
  updateDashboardRiskScore(user.id, "high");
  logEvent(user.id, "RATE_LIMIT_WARNING");
}
```

The dashboard’s risk score is calculated as a weighted average of:
- **Rate-limit usage** (30% weight)
- **Device fingerprint deviations** (25% weight)
- **Recent ban history** (20% weight)
- **Comment/like patterns** (25% weight)

For example, if a user’s rate-limit usage spikes to 90% and their device fingerprint changes (detected via `user-agent` and `IP`), the risk score jumps to 85/100, triggering an auto-pause. The user receives this email:

---
**Subject:** Inflact Safe-Mode Alert: Account Risk Detected
**Body:**
Your Instagram account’s risk score has increased to **85/100** due to:
- **Rate-limit usage:** 90% (threshold: 70%)
- **Device fingerprint change:** High risk (threshold: medium)

**Action Required:**
1. Verify your device in **Settings > Account Security**.
2. If you’re using a new device, update your profile in Inflact’s dashboard.

Safe-Mode has paused all automated actions until you confirm your account’s safety.
---

If the user confirms their account is safe, Inflact resumes actions and resets the risk score. For banned accounts, the support team initiates the **Account-Recovery SLA** by:
1. Sending a DM to Instagram’s support (via the official [Instagram Help Center](https://help.instagram.com/)) with the user’s case details.
2. Issuing a **2-month service credit** via Stripe refund.
3. Providing a step-by-step unban guide (e.g., "Change your password, remove suspicious follows, and wait 72 hours").

Here’s a worked example of a full growth cycle:
1. **User Action:** Enables Safe-Mode and sets a daily follow limit of 50 accounts.
2. **Inflact Backend:** Queues 50 follow requests to the HITL pool.
3. **HITL Execution:** Operators follow accounts one-by-one, logging timestamps and success/failure status.
4. **Risk Monitoring:** If the user’s rate-limit usage hits 80%, Inflact pauses follows and notifies the user.
5. **User Response:** The user adjusts their follow limit to 30/day.
6. **Completion:** By EOD, 30 accounts are followed, and
