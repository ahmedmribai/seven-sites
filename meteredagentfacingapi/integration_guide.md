# MeteredAgentfacingApi — Integration Guide

## 1. Architecture & System Overview

TokenGuard’s architecture is built on a **serverless, event-driven foundation** optimized for low-latency alerts and minimal operational overhead. The system is designed to poll LLM provider APIs (or receive webhook events where supported) every **5 minutes**, process spend data, and trigger Slack/email alerts when predefined thresholds are breached. This approach ensures **real-time responsiveness** without the complexity of a traditional backend, making it ideal for startups with limited DevOps resources. Below is a detailed breakdown of the system’s components, data flows, and technical implementation.

The core of TokenGuard’s architecture is a **polling engine** implemented as AWS Lambda functions, which are triggered via CloudWatch Events on a 5-minute interval. Each Lambda function fetches token usage data from the connected LLM provider (e.g., OpenAI, Anthropic) using the provider’s API, parses the response into a standardized format, and stores it in a lightweight database (Firebase Firestore). The database schema is intentionally minimal, storing only **aggregate spend data** (e.g., `total_tokens_used`, `current_spend`, `budget_limit`) and **user-specific metadata** (e.g., `user_id`, `team_id`, `provider_api_key_hash`). This design ensures **no PII is stored**, reducing compliance risks while maintaining the ability to track spend trends over time.

When a Lambda function processes spend data, it compares the current usage against the user’s configured budget threshold (e.g., 80% of their monthly budget). If the threshold is exceeded, the function triggers a **Slack/email alert pipeline** via another Lambda function dedicated to notifications. For Slack, this involves sending a **richly formatted message** with three key pieces of information:
1. **Current spend vs. budget** (e.g., *"You’re at 92% of your $500/month budget"*).
2. **Top 3 cost drivers** (e.g., *"Your `/generate` calls are 3x more expensive than average"*).
3. **One-click action buttons** (e.g., *"Batch these requests"* or *"Switch to a cheaper model"*).

The Slack message is constructed using the [Slack Incoming Webhooks API](https://api.slack.com/messaging/composing), with dynamic fields populated from the spend data. For example, the payload sent to Slack’s webhook endpoint looks like this:

```json
{
  "text": "⚠️ **TokenGuard Alert**: Your spend is approaching your budget limit.",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Current spend:* $460 (92% of $500 budget)\n*Remaining budget:* $40"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "📊 **Top 3 cost drivers:**"
      }
    },
    {
      "type": "section",
      "fields": [
        {
          "type": "mrkdwn",
          "text": "*`/generate` calls*"
        },
        {
          "type": "mrkdwn",
          "text": "*3x more expensive than average*"
        }
      ]
    },
    {
      "type": "actions",
      "elements": [
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "Batch these requests"
          },
          "url": "https://app.tokenguard.io/batch?team_id=123"
        },
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "Switch to a cheaper model"
          },
          "url": "https://app.tokenguard.io/models?team_id=123"
        }
      ]
    }
  ]
}
```

For email alerts, TokenGuard uses SendGrid’s transactional email API to send a similarly structured message, with the key differences being:
- **Plain-text fallback** for compatibility with older email clients.
- **HTML template** for richer formatting (e.g., tables for cost breakdowns).
- **Direct links** to the TokenGuard dashboard for further investigation.

The email payload includes a **one-click action** via a URL parameter (e.g., `?action=batch&team_id=123`), which redirects users to the TokenGuard dashboard with pre-selected optimization actions. This reduces friction in resolving alerts by guiding users directly to the most relevant cost-saving tools.

To handle **rate limits and API failures**, TokenGuard implements a **retry mechanism** with exponential backoff. If a Lambda function fails to fetch spend data from the LLM provider (e.g., due to a 429 Too Many Requests error), it retries the request after a delay that increases with each attempt (e.g., 1s → 2s → 4s). If the failure persists after 5 retries, the system logs the error in CloudWatch and continues polling the next interval. This ensures **high availability** even during provider outages or rate limit events.

The database schema in Firebase Firestore is structured as follows:

```plaintext
collections:
  users:
    documents: {user_id}
      fields:
        provider: string (e.g., "openai")
        api_key_hash: string (hashed for security)
        budget_limit: number (e.g., 500)
        budget_currency: string (e.g., "USD")
        email_notifications: boolean
        slack_webhook_url: string (optional)
        team_members: array of {member_id, role}
        last_alert_sent: timestamp

  spend_data:
    documents: {user_id}_{timestamp}
      fields:
        total_tokens_used: number
        current_spend: number
        spend_date: timestamp
        top_cost_drivers: array of {
          endpoint: string (e.g., "/generate"),
          tokens_used: number,
          cost_per_token: number,
          percentage_of_total: number
        }
```

For example, if a user with `user_id=abc123` spends $460 on tokens on `2024-05-20T14:30:00Z`, the Firestore document would look like this:

```json
{
  "user_id": "abc123",
  "total_tokens_used": 1200000,
  "current_spend": 460,
  "spend_date": "2024-05-20T14:30:00Z",
  "top_cost_drivers": [
    {
      "endpoint": "/generate",
      "tokens_used": 800000,
      "cost_per_token": 0.0004,
      "percentage_of_total": 66.67
    },
    {
      "endpoint": "/embeddings",
      "tokens_used":

## 2. Authentication & Security

TokenGuard’s **Authentication & Security** layer ensures that user credentials for LLM providers and Slack are handled with military-grade security while maintaining a frictionless integration experience. The system prioritizes **zero-trust principles**, meaning no raw API keys or tokens are stored in plaintext or transmitted over insecure channels. Instead, we implement a multi-layered approach combining **envelope encryption**, **short-lived credentials**, and **OAuth2 for Slack**, all while minimizing developer overhead.

---

****LLM Provider API Key Management****
To integrate with LLM providers like OpenAI, Anthropic, or Mistral, users must provide their API keys. These keys grant access to usage data, which is sensitive and must never be exposed or logged in a way that could compromise security. Here’s how TokenGuard secures this process:

1. **Client-Side Key Input with Zero Logging**
   Users input their LLM provider API keys directly in the TokenGuard dashboard via a **client-side form** (React frontend). No keys are transmitted to the backend unless explicitly required for authentication. The form enforces **client-side validation** (e.g., regex for OpenAI key patterns) before submission, and the browser’s built-in security mechanisms (HTTPS, CSP headers) prevent keylogging or interception.

2. **Envelope Encryption for Storage**
   When a user submits their API key, it is **never stored in plaintext**. Instead, TokenGuard’s backend uses **AWS KMS (Key Management Service)** to generate a unique **data encryption key (DEK)** for each user. The DEK is encrypted under a **master key** (stored in AWS KMS) and paired with the API key in an **envelope encryption** structure. The payload looks like this:

   ```json
   {
     "api_key_arn": "arn:aws:kms:us-east-1:123456789012:key/abcd1234-5678-90ef-ghij-klmnopqrstuv",
     "encrypted_dek": "AQIC5v...",  // Encrypted DEK under KMS master key
     "iv": "base64-encoded-initialization-vector",
     "ciphertext": "base64-encoded-api-key"  // Encrypted API key under DEK
   }
   ```

   - The `api_key_arn` references the KMS key used to encrypt the DEK.
   - The `encrypted_dek` is the DEK encrypted under the master key.
   - The `ciphertext` is the API key encrypted under the DEK.
   - The `iv` ensures deterministic encryption (same key → same ciphertext).

   To retrieve the API key, the backend:
   - Decrypts the `encrypted_dek` using the KMS master key.
   - Uses the decrypted DEK to decrypt the `ciphertext`, yielding the original API key.
   - The API key is **never stored long-term**; it’s only decrypted in memory during the authentication flow and immediately purged.

3. **Short-Lived Credentials for Polling**
   TokenGuard polls LLM providers for usage data every 5 minutes (or uses webhooks if supported). To minimize risk, the system generates **short-lived credentials** (e.g., 1-hour API tokens) for each polling request. These tokens are:
   - Scoped to **read-only** usage endpoints (e.g., `https://api.openai.com/v1/usage`).
   - Valid for **only 1 hour** (configurable via AWS IAM or provider-specific token policies).
   - Rotated automatically before expiration.

   Example AWS IAM policy for OpenAI polling:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "kms:Decrypt",
           "kms:GenerateDataKey"
         ],
         "Resource": "arn:aws:kms:us-east-1:123456789012:key/abcd1234-5678-90ef-ghij-klmnopqrstuv"
       },
       {
         "Effect": "Allow",
         "Action": [
           "openai:Usage:Read"
         ],
         "Resource": "*"
       }
     ]
   }
   ```

   The backend uses **AWS Lambda’s temporary credentials** (via IAM roles) to assume these policies dynamically.

4. **Rate Limiting and Throttling**
   To prevent abuse, TokenGuard enforces **strict rate limits** on API key usage:
   - **Max 10 polling requests per minute per user** (adjustable in Pro tier).
   - **Exponential backoff** for failed requests (e.g., `retry-after: 10s` for 429 errors).
   - **Provider-specific quotas**: OpenAI’s API has a default limit of 9,000 requests/minute for free tier users. TokenGuard respects these limits and alerts users if they’re approaching them.

   Example error handling for rate limits:
   ```javascript
   // Pseudocode for Lambda polling function
   async function pollUsage(apiKey, budget) {
     const response = await fetch('https://api.openai.com/v1/usage', {
       headers: {
         'Authorization': `Bearer ${apiKey}`,
         'Content-Type': 'application/json'
       }
     });

     if (response.status === 429) {
       const retryAfter = parseInt(response.headers.get('Retry-After'));
       console.log(`Rate limited. Retrying in ${retryAfter} seconds.`);
       await new Promise(resolve => setTimeout(resolve, retryAfter * 1000));
       return pollUsage(apiKey, budget); // Retry
     }

     if (!response.ok) {
       throw new Error(`Provider error: ${response.statusText}`);
     }

     const data = await response.json();
     // Process usage data...
   }
   ```

---

****Slack Integration via OAuth2****
TokenGuard integrates with Slack to send real-time alerts. Instead of storing Slack API tokens (which grant access to user data), we use **OAuth2 with a limited scope** to ensure users only grant the minimum necessary permissions. Here’s the step-by-step flow:

1. **User Initiates Slack Connection**
   When a user selects Slack as an alert channel, TokenGuard redirects them to Slack’s OAuth2 authorization endpoint:
   ```
   https://slack.com/oauth/v2/authorize?
     client_id=${CLIENT_ID}&
     scope=chat:write,users:read&
     redirect_uri=${ENCODED_REDIRECT_URI}
   ```
   - `client_id`: Registered in the Slack App Dashboard (e.g., `123456789012.abcdefghijklmnopqrstuvwxyz`).
   - `scope

## 3. Provider Integration Endpoints

TokenGuard’s integration with LLM providers is the backbone of its real-time cost monitoring. To track token spend accurately, the system must interface directly with provider APIs to fetch usage metrics, parse token consumption, and enforce budget thresholds. Below is a detailed breakdown of the endpoints, authentication flows, and polling mechanisms required for OpenAI, Anthropic, and custom LLM providers, including exact payloads, error handling, and rate limits.

---

For **OpenAI**, the primary integration point is the [`/usage`](https://platform.openai.com/docs/api-reference/usage) endpoint under the OpenAI API. This endpoint returns detailed token usage for a given API key, including prompt and completion tokens, along with timestamps. To poll usage effectively, TokenGuard must authenticate via an API key and query the endpoint every 5 minutes (or via webhooks if supported). Below is the exact request and response structure:

```http
POST /v1/usage?api_key=sk-xxx HTTP/1.1
Host: api.openai.com
Content-Type: application/json

{
  "model": "gpt-3.5-turbo",
  "total_tokens": 12345,
  "prompt_tokens": 4567,
  "completion_tokens": 7778,
  "total_cost": 0.0045,
  "timestamp": "2024-05-20T12:00:00Z"
}
```

The `total_cost` field is derived from OpenAI’s pricing tiers (e.g., `$0.002 per 1k tokens for gpt-3.5-turbo`). TokenGuard normalizes this into a standardized format for comparison against the user’s budget. For example, if a user’s budget is `$500/month` and their current spend is `$400`, the system calculates the percentage threshold (80%) and triggers an alert when usage exceeds this limit.

To handle rate limits, TokenGuard implements exponential backoff. OpenAI’s API enforces a **60 requests per minute** limit per API key. If this limit is hit, the system waits **1 second** before retrying, doubling the delay on subsequent failures (e.g., 2s, 4s, etc.). Error responses from OpenAI include a `rate_limit` field, which TokenGuard uses to adjust polling intervals dynamically:

```json
{
  "error": {
    "message": "You exceeded your current quota, please check your plan and billing details.",
    "type": "insufficient_quota",
    "rate_limit": {
      "remaining": 0,
      "reset": 1716123200
    }
  }
}
```

For **Anthropic**, the integration follows a similar pattern but uses the [`/usage`](https://docs.anthropic.com/claude/docs/usage-metrics) endpoint under the Anthropic API. Anthropic’s pricing is model-specific, with `claude-2` costing `$0.0015 per 1k tokens. The response payload includes `input_tokens` and `output_tokens`, which TokenGuard sums to calculate total token usage:

```http
POST /v1/usage?api_key=xxx HTTP/1.1
Host: api.anthropic.com
Content-Type: application/json

{
  "model": "claude-2",
  "input_tokens": 3000,
  "output_tokens": 2000,
  "total_tokens": 5000,
  "total_cost": 0.0075,
  "timestamp": "2024-05-20T12:00:00Z"
}
```

TokenGuard also supports **custom LLM providers** via a generic polling mechanism. Providers without dedicated APIs (e.g., self-hosted models) must expose a `/usage` endpoint that returns a standardized payload. For example:

```http
POST /usage HTTP/1.1
Host: custom-llm.example.com
Content-Type: application/json

{
  "model": "custom-gpt",
  "input_tokens": 1500,
  "output_tokens": 1000,
  "total_tokens": 2500,
  "cost_per_token": 0.001,
  "total_cost": 0.0025,
  "timestamp": "2024-05-20T12:00:00Z"
}
```

To ensure compatibility, TokenGuard validates the response schema against a strict JSON schema. If the payload is malformed or missing required fields, the system logs an error and retries after a delay:

```json
{
  "error": "Invalid payload: Missing 'total_tokens' field",
  "provider": "custom-llm.example.com",
  "retry_after": 30
}
```

For all providers, TokenGuard aggregates usage data in **5-minute intervals** and compares it against the user’s budget. If the spend exceeds 80% of the limit, the system triggers an alert via Slack or email. The alert payload includes:
- Current spend vs. budget (e.g., `"$320/$500"`).
- Top 3 cost drivers (e.g., `"Your /generate calls are 3x more expensive than average"`).
- One-click actions (e.g., `"Batch these requests"` or `"Switch to a cheaper model"`).

Below is a worked example of a Slack alert payload:

```json
{
  "text": "⚠️ **TokenGuard Alert:** Your spend is 64% of budget ($320/$500).",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Current spend:* $320\n*Budget:* $500\n*Remaining:* $180"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "📊 **Top 3 Cost Drivers:**\n1. `/generate` calls (3x average cost)\n2. Long prompts (1.5k tokens)\n3. Model: `gpt-3.5-turbo`"
      }
    },
    {
      "type": "actions",
      "elements": [
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "Batch Requests"
          },
          "url": "https://tokenguard.app/batch?model=gpt-3.5-turbo"
        },
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "Switch Model"
          },
          "url": "https://tokenguard.app/switch?model=gpt-4-32k"
        }
      ]
    }
  ]
}
```

TokenGuard’s

## 4. Budget Configuration & Threshold Management

To manage spending and prevent bill shock, TokenGuard utilizes a centralized budget configuration system. This system allows developers to define hard spending limits, establish tiered notification thresholds, and attribute costs to specific projects or teams. All budget configurations are managed via the `/budgets` endpoint, which supports granular control over how and when alerts are triggered.

The core data model for a budget is centered around the `budget_id`, a unique identifier that links a spending limit to a specific LLM provider key or a group of keys. The `limit_amount` is defined in USD (represented as a float), and the `period` defines the reset cycle—typically `monthly` or `lifetime`. To prevent a single unexpected spike from bypassing the system, TokenGuard employs "Tiered Thresholds." These are percentage-based triggers (e.g., 50%, 80%, 100%) that dictate when the Alert Engine should fire a notification. By default, TokenGuard initializes budgets with 80% and 100% thresholds, but these can be customized to provide early warnings for high-velocity spend.

To set up a new budget or update an existing one, send a `POST` request to `/v1/budgets`. The request body must include the `provider_id` (linked during the integration phase) and the desired `limit_amount`. For teams requiring cost attribution, the `scope` object allows you to tag the budget with a `project_name` or `team_id`, ensuring that Slack alerts specify exactly which part of the infrastructure is driving the cost.

```json
// POST /v1/budgets
{
  "provider_id": "prov_882341",
  "limit_amount": 500.00,
  "currency": "USD",
  "period": "monthly",
  "scope": {
    "project_name": "Customer-Support-Bot",
    "team_id": "ops_team_alpha"
  },
  "thresholds": [
    { "percentage": 50, "channel": "email" },
    { "percentage": 80, "channel": "slack" },
    { "percentage": 100, "channel": "slack" }
  ]
}
```

The API will respond with a `201 Created` status and a confirmation object containing the `budget_id` and the calculated `alert_values`. These alert values are the absolute dollar amounts that will trigger the notifications, providing a clear reference for the developer.

```json
// Response: 201 Created
{
  "budget_id": "bud_99021",
  "status": "active",
  "limit_amount": 500.00,
  "alert_values": {
    "50%": 250.00,
    "80%": 400.00,
    "100%": 500.00
  },
  "next_reset_date": "2023-11-01T00:00:00Z"
}
```

For existing budgets, use the `PATCH /v1/budgets/{budget_id}` endpoint to adjust limits on the fly. This is particularly useful for startups during a product launch when initial budgets may be too restrictive. When a limit is increased, TokenGuard recalculates the threshold triggers immediately. If the current spend already exceeds a newly lowered threshold, an alert is triggered instantly to notify the team of the breach.

Scope attribution is critical for organizations using a single API key across multiple environments. By utilizing the `scope` parameter, TokenGuard can aggregate spend across different `project_names` while still maintaining a global budget. For example, if you have a global budget of $1,000 but want to track "Staging" vs "Production" separately, you can create multiple budget objects linked to the same `provider_id` but with different `scope` tags. The system will track these as parallel limits, allowing you to identify if a leak is occurring in your testing environment before it impacts production funds.

To retrieve the current status of all budgets and see how close each is to its limit, use the `GET /v1/budgets` endpoint. This returns a list of all active budgets, the current spend polled from the provider, and the percentage of the budget consumed.

```json
// GET /v1/budgets
[
  {
    "budget_id": "bud_99021",
    "project_name": "Customer-Support-Bot",
    "current_spend": 412.50,
    "limit_amount": 500.00,
    "percent_used": 82.5,
    "status": "threshold_breached",
    "last_alert_sent": "2023-10-24T14:20:00Z"
  }
]
```

In the example above, the `status` is marked as `threshold_breached` because the spend ($412.50) has surpassed the 80% threshold ($400.00). This state triggers the Alert Engine to move from "Monitoring" to "Notifying," ensuring the team is alerted via the configured Slack channel. By combining strict dollar limits with flexible percentage thresholds and clear scope attribution, developers can move from reactive bill-shock management to proactive cost governance.

## 5. Real-Time Alert Engine & Payloads

The **Real-Time Alert Engine** is the heart of TokenGuard’s preventive cost control system, designed to intercept token spend before it spirals into bill shocks. It operates on a **5-minute polling cycle** via AWS Lambda, evaluating real-time usage against configured thresholds and dispatching actionable alerts via Slack or email. Below is the exact specification for the polling logic, threshold evaluation, and payload structures—everything a developer needs to implement this component.

---

The polling cycle begins with a Lambda function triggered every 5 minutes (using AWS EventBridge). The function fetches the latest token usage from the connected LLM provider (e.g., OpenAI’s API) and compares it against the user’s configured budget threshold. The threshold is stored in a lightweight database (Firebase) as a percentage of the total monthly budget (e.g., 80% for alerts). For example, if a user sets a $500/month budget, the threshold is calculated as `500 * 0.8 = 400 tokens`. The Lambda then queries the provider’s usage data for the past 5-minute interval and evaluates whether the current spend exceeds this threshold.

```javascript
// Example Lambda function snippet (simplified)
exports.handler = async (event) => {
  const { budget, thresholdPercentage } = await getUserBudgetFromFirebase(userId);
  const thresholdTokens = budget * (thresholdPercentage / 100);
  const currentUsage = await fetchTokenUsageFromProvider(apiKey);

  if (currentUsage > thresholdTokens) {
    const alertPayload = generateSlackPayload(currentUsage, thresholdTokens);
    await sendSlackAlert(alertPayload);
  }
};
```

If the threshold is breached, the Lambda constructs a **Slack/email payload** with three critical pieces of information: current spend vs. budget, top 3 cost drivers, and a one-click action. The payloads are designed to be **minimal but actionable**, avoiding information overload while ensuring users can immediately address the issue.

For Slack, the payload is a **rich message** with interactive buttons. Here’s the exact JSON structure:

```json
{
  "text": "🚨 TokenGuard Alert: Your spend is approaching budget limits!",
  "attachments": [
    {
      "color": "#FF0000",
      "title": "Current Spend vs. Budget",
      "title_link": "https://tokenguard.app/dashboard",
      "text": `You've used **${currentUsage} tokens** (${(currentUsage / budget) * 100}% of budget).`,
      "fields": [
        {
          "title": "Threshold Breached",
          "value": `80% of budget (${thresholdTokens} tokens)`,
          "short": true
        }
      ],
      "actions": [
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "Batch these requests",
            "emoji": true
          },
          "url": "https://tokenguard.app/batch?model=gpt-4"
        },
        {
          "type": "button",
          "text": {
            "type": "plain_text",
            "text": "Switch to cheaper model",
            "emoji": true
          },
          "url": "https://tokenguard.app/switch?model=gpt-3.5"
        }
      ]
    }
  ]
}
```

For email, the payload is a **transactional template** with a similar structure but optimized for readability:

```json
{
  "subject": "[TokenGuard] Your LLM spend is approaching limits",
  "text": `
    Hi [User],

    Your current token usage is **${currentUsage} tokens** (${(currentUsage / budget) * 100}% of budget).
    This exceeds your 80% threshold (${thresholdTokens} tokens).

    Top 3 cost drivers:
    1. `/generate` calls: 3x more expensive than average
    2. Long prompts: 15% of tokens wasted on padding
    3. Duplicate requests: 20% inefficiency

    Quick fixes:
    - [Batch these requests](#) (saves 25% tokens)
    - [Switch to gpt-3.5](#) (50% cheaper)
  `,
  "html": `
    <div>
      <h2>🚨 TokenGuard Alert</h2>
      <p>Your current spend is <strong>${currentUsage} tokens</strong> (${(currentUsage / budget) * 100}% of budget).</p>
      <p>Threshold breached: <strong>80%</strong> (${thresholdTokens} tokens).</p>
      <ul>
        <li><strong>Top 3 cost drivers:</strong></li>
        <li>/generate calls: 3x more expensive than average</li>
        <li>Long prompts: 15% of tokens wasted on padding</li>
        <li>Duplicate requests: 20% inefficiency</li>
      </ul>
      <div>
        <a href="https://tokenguard.app/batch">Batch these requests</a> (saves 25% tokens)
        <a href="https://tokenguard.app/switch">Switch to gpt-3.5</a> (50% cheaper)
      </div>
    </div>
  `
}
```

The **top 3 cost drivers** are derived from the provider’s usage logs, parsed to identify patterns like:
- **High-cost API calls** (e.g., `/generate` vs. `/completions`).
- **Prompt inefficiencies** (e.g., excessive token padding).
- **Duplicate or redundant requests** (detected via request fingerprinting).

The one-click actions are **pre-configured URLs** that either:
1. **Batch requests** (e.g., redirecting to a TokenGuard dashboard where users can group API calls to reduce token overhead).
2. **Switch models** (e.g., prompting users to migrate from `gpt-4` to `gpt-3.5` via a single click).

---
**Error Handling and Edge Cases:**
The Lambda includes retry logic for failed API calls (e.g., rate limits from OpenAI). If the provider’s API is unreachable, the function logs the error and schedules a retry in 10 minutes. For threshold misconfigurations (e.g., a user sets a threshold higher than their budget), the Lambda silently adjusts the threshold to 90% of the budget and logs the event for admin review.

**Rate Limits:**
The polling cycle is capped at **120 requests per hour per user** (adjustable via Firebase settings). If a user exceeds this, the Lambda throttles further requests and notifies them via Slack/email:

```json
{
  "text": "⚠️ Alert Throttled: You've hit the polling limit (120 requests/hour).",
  "attachments": [
    {

## 6. Cost Optimization & Recommendations API

The **Cost Optimization & Recommendations API** is the brain behind TokenGuard’s ability to not only alert users to impending budget overruns but to actively suggest actionable fixes. This API analyzes raw token spend data, decomposes it into actionable insights, and generates hyper-specific recommendations tailored to the user’s workflow. The core logic is built around three pillars: **cost attribution**, **behavioral pattern recognition**, and **provider-agnostic optimization heuristics**. Below is the exact implementation, including algorithmic logic, response schemas, and worked examples developers can deploy immediately.

---

The API operates on a **polling-based** or **webhook-driven** model, depending on the provider’s support. For providers like OpenAI, which lack native webhooks for token spend, TokenGuard polls usage data every 5 minutes via the provider’s API. For providers like Mistral or Anthropic, which support webhooks, the system registers a callback endpoint and processes real-time updates. In either case, the raw spend data is normalized into a standardized schema before optimization logic is applied. The key payload fields include:
- `total_tokens_used` (integer)
- `total_cost` (float, in USD)
- `model_usage` (array of objects with `model_name`, `tokens_used`, `cost_per_token`)
- `request_metadata` (array of objects with `endpoint`, `parameters`, `timestamp`, `user_id`)

The first step in optimization is **cost attribution**, where the system identifies the top 3 cost drivers. This is achieved through a weighted scoring algorithm that factors in:
1. **Absolute spend** (e.g., a `/generate` endpoint consuming 50% of the budget is a top driver).
2. **Cost per token variance** (e.g., a model with 3x the cost per token of the average is flagged).
3. **Frequency of usage** (e.g., a low-cost endpoint called 100x/week is more impactful than a high-cost endpoint called once).

Here’s the exact logic in pseudocode, implemented as a serverless function (e.g., AWS Lambda):

```python
def identify_cost_drivers(raw_spend_data, budget_limit):
    # Step 1: Normalize data and calculate totals
    total_tokens = sum([item['tokens_used'] for item in raw_spend_data['model_usage']])
    total_cost = raw_spend_data['total_cost']
    spend_percentage = (total_cost / budget_limit) * 100

    # Step 2: Calculate cost per token for each model
    model_costs = {}
    for model in raw_spend_data['model_usage']:
        model_costs[model['model_name']] = {
            'tokens_used': model['tokens_used'],
            'cost_per_token': model['cost_per_token'],
            'total_cost': model['tokens_used'] * model['cost_per_token']
        }

    # Step 3: Score each request by:
    # - Absolute cost contribution (weight: 0.5)
    # - Cost per token deviation from average (weight: 0.3)
    # - Frequency of usage (weight: 0.2)
    average_cost_per_token = total_cost / total_tokens
    requests_sorted = sorted(
        raw_spend_data['request_metadata'],
        key=lambda x: (
            (x['total_cost'] / total_cost) * 0.5 +
            abs((x['cost_per_token'] - average_cost_per_token) / average_cost_per_token) * 0.3 +
            (x['call_count'] / len(raw_spend_data['request_metadata'])) * 0.2
        ),
        reverse=True
    )

    # Step 4: Return top 3 drivers
    top_drivers = []
    for request in requests_sorted[:3]:
        top_drivers.append({
            'endpoint': request['endpoint'],
            'model': request['model'],
            'tokens_used': request['tokens_used'],
            'cost_contribution': request['total_cost'] / total_cost,
            'savings_potential': estimate_savings_potential(request)
        })

    return {
        'spend_percentage': spend_percentage,
        'top_drivers': top_drivers,
        'recommendations': generate_recommendations(top_drivers, raw_spend_data)
    }
```

The `estimate_savings_potential` function uses provider-specific heuristics to project cost savings. For example, if a user is calling `/chat/completions` with `temperature=1.2`, the system might suggest reducing `temperature` to `0.7`, which historically reduces token usage by ~20%. The function queries a pre-populated knowledge base of optimization patterns (e.g., `{"temperature": {"reduction": 0.5, "savings": 0.2}, "max_tokens": {"reduction": 0.3, "savings": 0.15}}`) and applies the highest-impact adjustment first.

---

The **recommendations engine** generates one-click actions by cross-referencing the top cost drivers with a library of optimization templates. Each template includes:
1. **The problem** (e.g., "Your `/generate` calls are 3x more expensive than average").
2. **The root cause** (e.g., "Using `gpt-4` instead of `gpt-3.5-turbo`").
3. **The fix** (e.g., "Switch to `gpt-3.5-turbo` and reduce `max_tokens` by 20%").
4. **Estimated savings** (e.g., "$120/month").
5. **Implementation code snippet** (e.g., a modified API call).

Here’s a worked example of the response payload for a user whose top cost driver is a `/chat/completions` endpoint using `gpt-4` with `temperature=1.0`:

```json
{
  "alert_type": "cost_optimization",
  "spend_percentage": 92,
  "top_drivers": [
    {
      "endpoint": "/chat/completions",
      "model": "gpt-4",
      "tokens_used": 150000,
      "cost_contribution": 0.75,
      "savings_potential": {
        "current_cost": 120.00,
        "recommended_cost": 48.00,
        "savings": 72.00,
        "savings_percentage": 0.6
      }
    }
  ],
  "recommendations": [
    {
      "title": "Switch to gpt-3.5-turbo and reduce temperature",
      "description": "Your `/chat/completions` calls are using `gpt-4`, which is 3x more expensive than `gpt-3.5-turbo`. Reducing `temperature` to 0.7 can further reduce token usage by 15%.",
      "

## 7. Error Handling & Rate Limiting

TokenGuard’s integration relies on robust error handling and rate-limiting to ensure reliability, especially when polling LLM providers or sending alerts. Unhandled errors or throttled requests could disrupt alerts, leading to missed budget thresholds or false positives. Below are the standardized error response formats, HTTP status codes, retry logic, and rate-limiting specifications to implement.

---

All API responses from TokenGuard’s backend (AWS Lambda) and provider integrations (OpenAI, Anthropic, etc.) follow a consistent JSON structure for errors. Errors include a `status`, `code`, `message`, and `details` field, where `details` may contain provider-specific metadata. For example, a failed provider API call returns:

```json
{
  "status": "error",
  "code": "provider_api_failure",
  "message": "Failed to fetch usage data from OpenAI API",
  "details": {
    "provider": "openai",
    "error_type": "rate_limit_exceeded",
    "retry_after": 60,
    "provider_response": {
      "error": {
        "message": "You have exceeded your current quota",
        "type": "insufficient_quota",
        "code": "rate_limit_exceeded"
      }
    }
  }
}
```

HTTP status codes are used to indicate success or failure:
- **200 OK**: Request succeeded.
- **202 Accepted**: Alert triggered (async operation).
- **400 Bad Request**: Invalid payload (e.g., malformed budget threshold).
- **401 Unauthorized**: Missing or invalid API key.
- **403 Forbidden**: Insufficient permissions (e.g., free tier limit reached).
- **408 Request Timeout**: Provider API timeout (retry logic applies).
- **429 Too Many Requests**: Rate limit exceeded (retry with backoff).
- **500 Internal Server Error**: TokenGuard backend failure (retries capped at 3).

---

Retry logic is critical for polling provider APIs, which may throttle or fail intermittently. TokenGuard implements exponential backoff with jitter for retries, ensuring graceful degradation. For example, when polling OpenAI’s usage data:

```python
import time
import random

def poll_provider(max_retries=3, initial_delay=1):
    for attempt in range(max_retries):
        try:
            response = requests.get(
                "https://api.openai.com/v1/usage",
                headers={"Authorization": f"Bearer {api_key}"}
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            if attempt == max_retries - 1:
                raise  # Final retry failed
            delay = initial_delay * (2 ** attempt) + random.uniform(0, 1)
            time.sleep(delay)
```

Key retry parameters:
- **Initial delay**: 1 second (scales exponentially).
- **Max retries**: 3 attempts per poll.
- **Jitter**: Random delay (±0.5s) to avoid thundering herd problems.
- **Timeout**: 30 seconds per request (configurable).

If retries fail, TokenGuard logs the error and skips the poll cycle, ensuring alerts aren’t delayed indefinitely. For Slack/email alerts, retries are limited to 2 attempts with a 5-second delay between attempts to avoid spamming users.

---

Rate limiting is enforced at two levels: **provider-side** (e.g., OpenAI’s API limits) and **TokenGuard-side** (to prevent abuse of its own alerts). Provider APIs typically impose limits like:
- **OpenAI**: 9,000 requests/minute (free tier), 20,000 requests/minute (paid).
- **Anthropic**: 10,000 tokens/minute (free tier), 100,000 tokens/minute (paid).
- **Azure OpenAI**: 1,000 RPS (regional limits apply).

TokenGuard’s backend enforces its own limits:
- **Free tier**: 3 users, 10 alerts/day (Slack/email combined).
- **Pro tier**: Unlimited users, 50 alerts/day.
- **Polling rate**: 5-minute intervals (configurable via `poll_interval` setting).

To handle rate limits gracefully, TokenGuard checks `Retry-After` headers in provider responses and adjusts its polling schedule. For example, if OpenAI returns a `429` with `Retry-After: 60`, TokenGuard waits 60 seconds before retrying. Here’s a worked example of handling a rate-limited response:

```python
def handle_rate_limit(response):
    if response.status_code == 429:
        retry_after = int(response.headers.get("Retry-After", 60))
        time.sleep(retry_after)
        return poll_provider()  # Retry after delay
    return response
```

For Slack API calls, TokenGuard respects Slack’s rate limits (e.g., 1,000 messages/minute per user) by batching alerts and using Slack’s `chat.postMessage` with `wait` parameter set to `false` for async delivery.

---

Error handling for cost optimization recommendations is separate from polling errors. If TokenGuard’s recommendation engine fails (e.g., due to missing usage data), it logs the error and skips the recommendation for that user. Example payload for a failed recommendation:

```json
{
  "status": "error",
  "code": "recommendation_failed",
  "message": "Could not generate recommendations due to insufficient usage data",
  "details": {
    "missing_data": ["model_usage", "prompt_lengths"],
    "retry_suggestion": "Wait 1 hour and try again"
  }
}
```

Developers integrating TokenGuard should handle these errors by:
1. **Logging**: Store errors in a structured format (e.g., JSON logs) for debugging.
2. **User Notifications**: If alerts are missed due to rate limits, notify users via Slack/email with a message like:
   > *"Your token usage alert was delayed due to provider rate limits. Check your spend at [dashboard link]."*
3. **Fallbacks**: For critical alerts (e.g., 90% budget threshold), TokenGuard prioritizes delivery over others.

---

Worked example: **Handling a failed provider poll and retrying**
Assume TokenGuard is polling OpenAI’s usage data for a user with a budget threshold of 80% spend. The first poll fails due to a `429` response:

```python
# Initial poll (fails with 429)
response = requests.get("https://api.openai.com/v1/usage", headers={"Authorization": "Bearer API_KEY"})
if response.status_code == 429:
    retry_after = int(response.headers.get("Retry-After", 60))
    print(f"Rate limited. Retrying in {retry_after} seconds...")
    time.sleep(retry_after)

# Retry after delay
response = requests.get("https://api.openai.com/v

## 8. Freemium Tiering & Billing Limits

TokenGuard’s freemium model is designed to maximize adoption while ensuring sustainable revenue by clearly defining feature access, user limits, and billing thresholds. The system enforces these constraints through a combination of server-side logic, database checks, and API-level gatekeeping. Below is the exact implementation for each tier, including enforcement mechanisms, user seat restrictions, and feature gating.

---

The **Free tier** is limited to **three active users** and provides core functionality: real-time Slack/email alerts when token spend reaches 80% of a self-defined budget. No cost optimization recommendations or team collaboration features are available. To prevent abuse, the Free tier enforces a **$50 monthly spend cap** (hard limit, not a soft alert). If a user’s cumulative spend exceeds $50 in a calendar month, all alerts are disabled until the next month, and a one-time email notification is sent explaining the limit. This cap is enforced via a serverless function that runs daily at midnight, recalculating spend and resetting the limit. The function checks the `user_id` against the `tier` field in the database and compares the `total_spend` against the tier-specific cap. If exceeded, it updates the `tier` to `"disabled"` and sends the email via SendGrid.

```javascript
// Serverless function (AWS Lambda) to enforce Free tier limits
exports.handler = async (event) => {
  const { userId } = event;
  const db = await admin.firestore().collection('users').doc(userId).get();

  if (db.data().tier === 'free' && db.data().total_spend >= 50) {
    await admin.firestore().collection('users').doc(userId).update({
      tier: 'disabled',
      lastAlert: new Date().toISOString(),
    });

    await sendEmail({
      to: db.data().email,
      subject: 'TokenGuard Free Tier Limit Reached',
      body: `Your free tier has hit the $50 monthly spend cap. Alerts are disabled until next month. Upgrade to Pro for unlimited spend tracking.`,
    });
  }
};
```

The **Pro tier** ($20/month) removes all limits: users gain access to **cost-per-prompt analytics**, **model recommendations**, and **team collaboration features** (up to 10 users). Pro users also receive **priority support** via Slack DMs and access to a dedicated Slack channel for community discussions. Billing is handled via Stripe, with subscriptions auto-renewing monthly. The system checks for Pro tier access at the API level before allowing cost optimization recommendations or team-related endpoints. For example, the `/cost_optimization` endpoint returns a `403 Forbidden` error if the user’s tier is not Pro:

```http
# Example request to /cost_optimization (Pro-only)
GET /api/v1/cost_optimization?model=gpt-4 HTTP/1.1
Authorization: Bearer <user_api_key>
```

```json
# Response if user is Free tier
{
  "error": "Feature not available in Free tier",
  "code": "UNAUTHORIZED",
  "recommendation": "Upgrade to Pro for cost-per-prompt insights and model recommendations."
}
```

User seat restrictions are enforced via a `user_count` field in the database. When a Pro user invites additional team members, the system checks if the total number of active users (including the inviter) exceeds 10. If so, the invitation is rejected with a clear error message:

```javascript
// Logic for handling team invites (Pro tier only)
const maxTeamSize = 10;
const currentUser = await getUser(userId);
const invitedUser = await getUser(invitedUserId);

if (currentUser.team_members.length >= maxTeamSize) {
  return {
    success: false,
    message: `Team size limit reached (${maxTeamSize} users). Upgrade to a higher plan for more seats.`,
  };
}
```

Feature gating is implemented at the API endpoint level using middleware. For instance, the `/recommendations` endpoint checks the user’s tier before processing the request. If the user is Free, the endpoint returns a simplified response with generic cost-saving tips (e.g., "Use shorter prompts") instead of model-specific recommendations:

```javascript
// Example middleware for feature gating
app.use('/api/v1/recommendations', (req, res, next) => {
  const user = req.user;
  if (user.tier !== 'pro') {
    return res.json({
      generic_tips: [
        "Batch API calls to reduce token overhead.",
        "Trim whitespace and unnecessary tokens from prompts.",
      ],
      upgrade_link: "https://tokenguard.app/upgrade",
    });
  }
  next();
});
```

To prevent users from bypassing limits, the system logs all API calls and enforces rate limits. Free tier users are restricted to **50 API calls per minute** (for polling usage data), while Pro users have no rate limits. Rate limits are enforced using AWS WAF or a custom middleware layer that checks the request count against a Redis cache:

```javascript
// Rate limiting middleware (example using Redis)
const rateLimit = async (req, res, next) => {
  const key = `rate_limit:${req.user.id}`;
  const current = await redis.get(key);
  const limit = req.user.tier === 'free' ? 50 : Infinity;

  if (current && parseInt(current) >= limit) {
    return res.status(429).json({
      error: "Rate limit exceeded",
      retry_after: 60, // seconds
    });
  }

  await redis.incr(key);
  redis.expire(key, 60); // Reset after 60 seconds

  next();
};
```

For billing, Stripe handles subscription management, and the system syncs user tiers daily. If a Pro user’s subscription lapses, all Pro-only features are immediately disabled, and the user is downgraded to Free tier with a notification:

```javascript
// Stripe webhook handler for subscription changes
exports.handler = async (event) => {
  const { data } = event;
  const userId = data.object.customer;

  if (data.object.status === 'inactive') {
    await admin.firestore().collection('users').doc(userId).update({
      tier: 'free',
      last_billing_update: new Date().toISOString(),
    });

    await sendEmail({
      to: getUserEmail(userId),
      subject: 'TokenGuard Subscription Ended',
      body: `Your Pro tier has expired. Alerts and cost optimization features are now limited to Free tier. Renew at any time.`,
    });
  }
};
```

Worked example: A Free tier user named Alex (user_id: `alex123`) sets a $30 budget. TokenGuard polls OpenAI’s API usage every 5 minutes and calculates spend. When Alex’s spend reaches $24 (80% of $30), a Slack alert is sent:

```
🚨 Token

## 9. End-to-End Walkthrough

Here’s your **End-to-End Walkthrough** for the **MeteredAgentfacingApi** integration guide. This section is designed to be a **step-by-step, copy-paste-ready** manual for developers to set up TokenGuard in under 30 minutes, from account creation to triggering a simulated alert.

---

Start by navigating to [TokenGuard’s signup page](https://app.tokenguard.ai/signup) and clicking **"Get Started for Free."** The form will prompt you for your **email address**, **company name**, and **Slack workspace URL** (if you want to enable Slack alerts immediately). Fill in the details with your actual credentials—TokenGuard will verify your email and Slack workspace in real time. For example:

```plaintext
Email: dev@example.com
Company: MyDevToolsInc
Slack Workspace: https://mydevtools.slack.com
```

Once submitted, you’ll receive a confirmation email with a link to **complete your account setup**. Click the link and log in to the **TokenGuard dashboard**. The dashboard will display a **temporary free-tier budget limit of $50/month** (for testing purposes) and a placeholder for your LLM provider API keys. Your **user ID** will be auto-generated as `user_abc123xyz`—this is used for all API calls and will appear in alerts.

---

****Step 2: Connect Your LLM Provider API Key****
TokenGuard supports **OpenAI, Anthropic, and Mistral** out of the box. To connect your API key, click the **"Add Provider"** button in the dashboard and select your provider. For this example, we’ll use **OpenAI**. Paste your **actual API key** (found in your OpenAI account under **Settings > View API Keys**) into the input field. TokenGuard will **immediately validate** the key by making a test request to OpenAI’s `/v1/models` endpoint. If successful, you’ll see a confirmation message like this:

```plaintext
✅ API Key Validated: sk-abc123xyz (OpenAI)
```

If the key fails validation, TokenGuard will return a **specific error message** (e.g., `"Invalid API Key: 401 Unauthorized"`) along with a **troubleshooting guide** in the dashboard. For example, if you accidentally pasted a placeholder key, you’ll see:

```json
{
  "error": {
    "code": "API_KEY_INVALID",
    "message": "The provided API key is not valid. Double-check your key in the OpenAI dashboard.",
    "suggestions": [
      "Verify the key in OpenAI’s API keys section.",
      "Regenerate the key if it was accidentally exposed."
    ]
  }
}
```

---

****Step 3: Configure Your Budget Threshold****
With your API key linked, navigate to the **"Budget Settings"** tab in the dashboard. Here, you’ll set your **monthly spend limit** and **alert percentage**. For testing, we recommend setting a **low threshold** (e.g., **$10/month**) to trigger alerts quickly. Enter:

- **Monthly Budget:** `$10`
- **Alert Percentage:** `80%` (so you’ll get notified when you hit **$8**)

Click **"Save Settings."** TokenGuard will now **poll your LLM provider every 5 minutes** (via the `/usage` endpoint) to track your token spend. The dashboard will update in real time, showing:

```plaintext
Current Spend: $0.45 (4.5% of budget)
Last Updated: 2 minutes ago
```

---

****Step 4: Simulate Token Usage and Trigger an Alert****
To test the alert system, you’ll **manually simulate token usage** by making API calls to your connected LLM provider. Open a terminal and use `curl` to call OpenAI’s `/v1/completions` endpoint with a **small payload** (e.g., a 10-token prompt). For example:

```bash
curl https://api.openai.com/v1/completions \
  -H "Authorization: Bearer sk-abc123xyz" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-3.5-turbo",
    "prompt": "Explain blockchain in 3 sentences.",
    "max_tokens": 10
  }'
```

After running this command, check the **TokenGuard dashboard**. You’ll see your **spend update** (e.g., `$0.02` added to your total). Repeat this command **10 times** to simulate **$0.20 in spend**. At this point, your dashboard will show:

```plaintext
Current Spend: $0.20 (2% of budget)
Status: Safe
```

Now, to **trigger an alert**, run the same command **another 40 times** (totaling **$1.60 in spend**). When your spend reaches **$8.00 (80% of your $10 budget)**, TokenGuard will **instantly send a Slack alert** to your workspace with this payload:

```json
{
  "alert_type": "BUDGET_THRESHOLD_BREACH",
  "user_id": "user_abc123xyz",
  "provider": "openai",
  "current_spend": 8.00,
  "budget": 10.00,
  "percentage_used": 80,
  "top_cost_drivers": [
    {
      "endpoint": "/v1/completions",
      "tokens_used": 420,
      "cost_per_1k_tokens": 0.02,
      "recommendation": "Batch these requests to reduce cost."
    }
  ],
  "action_button": {
    "label": "Batch Requests",
    "url": "https://app.tokenguard.ai/optimize?user=user_abc123xyz"
  }
}
```

The Slack message will include a **one-click button** labeled **"Batch Requests"** that links to TokenGuard’s optimization dashboard. If you’re not using Slack, TokenGuard will **simultaneously send an email alert** with the same details:

---
**Subject:** ⚠️ Your TokenGuard Alert: $8.00 Spent (80% of $10 Budget)
**Body:**
> Hi Dev Team,
>
> Your LLM spend has hit **80% of your $10 budget** ($8.00 used).
>
> **Top Cost Drivers:**
> - `/v1/completions` (420 tokens, $0.02 per 1k tokens)
>
> **Action:** [Batch these requests to save 30%](https://app.tokenguard.ai/optimize?user=user_abc123xyz)
>
> — TokenGuard

---

****Step 5: Verify the Alert and Take Action****
Click the **"Batch Requests"** button in Slack (or follow
