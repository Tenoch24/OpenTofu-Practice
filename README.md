# Support Ticket Classifier Pipeline

**Scenario C — Big Data · Universidad Autónoma de Guadalajara**

A fully automated support-ticket triage system deployed on AWS with a single command.  
Three Lambda functions orchestrated by Step Functions classify every incoming ticket as `urgent`, `normal`, or `low` and store the result in S3 — **zero console clicks required**.

> **Stack:** OpenTofu · AWS Lambda (Python 3.11) · Step Functions · S3 · IAM

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Architecture](#architecture)
3. [Data Flow — JSON at every stage](#data-flow--json-at-every-stage)
4. [Lambda Functions](#lambda-functions)
5. [Step Functions State Machine](#step-functions-state-machine)
6. [IAM Security Model](#iam-security-model)
7. [Infrastructure Module](#infrastructure-module)
8. [Folder Structure](#folder-structure)
9. [Prerequisites](#prerequisites)
10. [Deployment](#deployment)
11. [Testing](#testing)
12. [Destroy](#destroy)
13. [Technical Constraints Checklist](#technical-constraints-checklist)

---

## How It Works

A ticket arrives as a JSON event with four fields:

```json
{
  "ticket_id":      "tk-001",
  "customer":       "student@uag.mx",
  "priority_score": 90,
  "description":    "The system has been unresponsive for 2 hours, affecting all users"
}
```

It passes through three Lambda functions in sequence:

```
L1 ticket-validator  →  L2 ticket-classifier  →  L3 ticket-router  →  S3
```

Each Lambda **receives the full event** and **returns it enriched** with additional fields, preserving every key from the previous step. If L1 fails, execution stops immediately — L2 and L3 never run.

---

## Architecture

```
  Input JSON
      │
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  AWS Step Functions State Machine                    │
│                   "ticket-classifier-pipeline"                       │
│                                                                      │
│   ┌─────────────────┐       ┌──────────────────┐                    │
│   │  ValidateTicket  │──────▶│  ClassifyTicket   │                   │
│   │   Task (L1)      │       │   Task (L2)        │                   │
│   └────────┬─────────┘       └────────┬─────────┘                   │
│            │ on error                 │                              │
│            ▼                          ▼                              │
│   ╔══════════════════╗      ┌──────────────────────┐                │
│   ║ ValidationFailed ║      │   RouteByseverity     │               │
│   ║   Fail  ✗        ║      │   Choice  (3 branches)│               │
│   ╚══════════════════╝      └───┬──────────┬────┬──┘                │
│                              urgent     normal  low                  │
│                                 └──────────┴────┘                   │
│                                            │                         │
│                                 ┌──────────▼──────────┐             │
│                                 │     StoreTicket      │             │
│                                 │      Task (L3)        │             │
│                                 └──────────┬──────────┘             │
│                                            │ on error               │
│                              ┌─────────────┼──────────────────┐     │
│                              ▼             ▼                   │     │
│                   ╔═══════════════╗  ┌──────────────┐         │     │
│                   ║ RoutingFailed ║  │TicketProcessed│         │     │
│                   ║   Fail  ✗     ║  │  Succeed  ✓  │         │     │
│                   ╚═══════════════╝  └──────────────┘         │     │
└─────────────────────────────────────────────────────────────────────┘
                                            │
                                            ▼
                             s3://ticket-classifier-pipeline/
                             ├── urgent/  tk-001_20260504T120000Z.json
                             ├── normal/  tk-002_20260504T120100Z.json
                             └── low/     tk-003_20260504T120200Z.json
```

---

## Data Flow — JSON at every stage

This shows exactly what the event looks like as it moves through the pipeline.

### Input (sent to Step Functions)

```json
{
  "ticket_id":      "tk-001",
  "customer":       "student@uag.mx",
  "priority_score": 90,
  "description":    "The system has been unresponsive for 2 hours, affecting all users"
}
```

### After L1 — ticket-validator

```json
{
  "ticket_id":          "tk-001",
  "customer":           "student@uag.mx",
  "priority_score":     90,
  "description":        "The system has been unresponsive for 2 hours, affecting all users",
  "validated":          true,
  "validation_message": "All fields passed validation"
}
```

### After L2 — ticket-classifier

```json
{
  "ticket_id":               "tk-001",
  "customer":                "student@uag.mx",
  "priority_score":          90,
  "description":             "The system has been unresponsive for 2 hours, affecting all users",
  "validated":               true,
  "validation_message":      "All fields passed validation",
  "severity":                "urgent",
  "urgent_keywords_matched": 1,
  "low_keywords_matched":    0,
  "classification_message":  "Ticket classified as 'urgent' (score=90, urgent_kw=1, low_kw=0)"
}
```

### After L3 — ticket-router (final output, stored in S3)

```json
{
  "ticket_id":               "tk-001",
  "customer":                "student@uag.mx",
  "priority_score":          90,
  "description":             "The system has been unresponsive for 2 hours, affecting all users",
  "validated":               true,
  "validation_message":      "All fields passed validation",
  "severity":                "urgent",
  "urgent_keywords_matched": 1,
  "low_keywords_matched":    0,
  "classification_message":  "Ticket classified as 'urgent' (score=90, urgent_kw=1, low_kw=0)",
  "routed":                  true,
  "s3_bucket":               "ticket-classifier-pipeline",
  "s3_key":                  "urgent/tk-001_20260504T120000Z.json",
  "routing_message":         "Stored at s3://ticket-classifier-pipeline/urgent/tk-001_20260504T120000Z.json"
}
```

### On validation failure (ValidationFailed Fail state)

```json
{
  "ticket_id":      "",
  "customer":       "",
  "priority_score": 150,
  "description":    ""
}
```

L1 raises `ValueError: Validation failed: Missing required field: ticket_id; Missing required field: customer; priority_score must be between 0 and 100; description must be a non-empty string` — Step Functions catches it and terminates at `ValidationFailed`.

---

## Lambda Functions

### L1 — ticket-validator (`lambdas/validate/lambda_function.py`)

Validates the raw input. All four fields must pass — **a single failure raises an exception** and stops the pipeline.

| Field | Validation rule |
|---|---|
| `ticket_id` | Present and non-empty string |
| `customer` | Present and non-empty string |
| `priority_score` | Numeric value in range `[0, 100]` |
| `description` | Non-empty string |

**Adds to event:** `validated` (bool), `validation_message` (str)

---

### L2 — ticket-classifier (`lambdas/classify/lambda_function.py`)

Applies **two independent signals** — score and keyword scan — to assign a severity.

| Condition | Result |
|---|---|
| `priority_score >= 70` **or** any urgent keyword in description | `urgent` |
| `priority_score <= 35` **and** no urgent keywords **and** any low keyword | `low` |
| Everything else | `normal` |

**Urgent keywords** (raise severity):
`urgent` · `emergency` · `critical` · `down` · `outage` · `not working` · `unresponsive` · `broken` · `crash` · `failure`

**Low keywords** (lower severity, only when no urgent signals):
`question` · `inquiry` · `how to` · `documentation` · `feedback` · `suggestion` · `info` · `curious`

**Adds to event:** `severity`, `urgent_keywords_matched`, `low_keywords_matched`, `classification_message`

---

### L3 — ticket-router (`lambdas/route/lambda_function.py`)

Writes the fully-enriched event to S3 using the key pattern:

```
<severity>/<ticket_id>_<UTC-timestamp>.json
```

The S3 client reads `BUCKET_NAME` from an environment variable injected by OpenTofu at deploy time.

**Adds to event:** `routed`, `s3_bucket`, `s3_key`, `routing_message`

---

## Step Functions State Machine

Defined entirely in `step_function.tf` using `jsonencode()`. Exactly **7 states** (class maximum):

| # | State name | Type | On success | On error |
|---|---|---|---|---|
| 1 | `ValidateTicket` | Task | → ClassifyTicket | → ValidationFailed |
| 2 | `ClassifyTicket` | Task | → RouteByseverity | → ValidationFailed |
| 3 | `RouteByseverity` | Choice | → StoreTicket (all 3 branches) | — |
| 4 | `StoreTicket` | Task | → TicketProcessed | → RoutingFailed |
| 5 | `TicketProcessed` | Succeed | terminal ✓ | — |
| 6 | `ValidationFailed` | Fail | — | terminal ✗ |
| 7 | `RoutingFailed` | Fail | — | terminal ✗ |

The Choice state uses `StringEquals` on `$.severity` with three explicit branches (`urgent`, `normal`, `low`) plus a `Default` that also goes to `StoreTicket`, making it impossible for a classified ticket to be dropped.

---

## IAM Security Model

Two roles are created in `iam.tf`. Neither has wildcard resource permissions.

### `ticket-classifier-lambda-role`

Assumed by: `lambda.amazonaws.com`

| Permission | Scope |
|---|---|
| CloudWatch Logs (write) | Via AWS managed policy `AWSLambdaBasicExecutionRole` |
| `s3:PutObject`, `s3:GetObject` | Inline policy — scoped to `ticket-classifier-pipeline/*` only |

### `ticket-classifier-sfn-role`

Assumed by: `states.amazonaws.com`

| Permission | Scope |
|---|---|
| `lambda:InvokeFunction` | Inline policy — scoped to the three Lambda ARNs only |

---

## Infrastructure Module

The reusable module at `modules/lambda_function/` is called three times in `main.tf`, once per Lambda. It does two things:

1. **Zips the source directory** using the `archive_file` data source (no shell commands, cross-platform)
2. **Creates the Lambda function** with the zip, runtime, handler, role, env vars, and tags

```
modules/lambda_function/
├── main.tf        # archive_file + aws_lambda_function
├── variables.tf   # function_name, source_dir, role_arn, environment_variables, project_tag
└── outputs.tf     # function_arn, function_name
```

The module outputs `function_arn` which `step_function.tf` uses to build the state machine definition — no hardcoded ARNs anywhere.

---

## Folder Structure

```
.
├── main.tf                          # Providers, S3 bucket, three Lambda module calls
├── iam.tf                           # IAM roles and least-privilege policies
├── variables.tf                     # aws_region, project_name, bucket_name (all with defaults)
├── outputs.tf                       # state_machine_arn, s3_bucket_name
├── step_function.tf                 # Full state machine definition (7 states)
│
├── modules/
│   └── lambda_function/             # Reusable Lambda module (zip + deploy)
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── lambdas/
│   ├── validate/
│   │   └── lambda_function.py       # L1 — validates ticket_id, customer, score, description
│   ├── classify/
│   │   └── lambda_function.py       # L2 — score + keyword → urgent / normal / low
│   └── route/
│       └── lambda_function.py       # L3 — writes enriched JSON to S3
│
└── tests/
    ├── test_urgent.json             # score=90, "unresponsive" keyword  →  urgent branch
    ├── test_normal.json             # score=55, no keywords             →  normal branch
    ├── test_low.json                # score=20, "question" keyword      →  low branch
    └── test_invalid.json            # empty fields, score=150           →  ValidationFailed
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| OpenTofu | >= 1.6.0 | [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install/) |
| AWS CLI | v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| AWS credentials | — | IAM user or role with Lambda + Step Functions + S3 + IAM permissions |

Configure and verify credentials:

```bash
aws configure
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region name:   us-east-1
# Default output format: json

aws sts get-caller-identity   # should print your Account ID
```

---

## Deployment

### 1 — Initialize

Downloads providers (`hashicorp/aws`, `hashicorp/archive`) and links the local module.

```bash
tofu init
```

### 2 — Preview

Shows every resource that will be created before touching AWS.

```bash
tofu plan
```

### 3 — Deploy

Creates all resources in the correct dependency order. Takes ~30 seconds.

```bash
tofu apply
```

At the end OpenTofu prints:

```
Apply complete! Resources: 10 added, 0 changed, 0 destroyed.

Outputs:

s3_bucket_name    = "ticket-classifier-pipeline"
state_machine_arn = "arn:aws:states:us-east-1:ACCOUNT_ID:stateMachine:ticket-classifier-pipeline"
```

These two outputs are used in every test command below.

---

## Testing

### Quick check — invoke each Lambda directly

Good for verifying a single function without running the full pipeline.

**Validate a correct ticket (expect `"validated": true`)**

```bash
aws lambda invoke \
  --function-name ticket-validator \
  --cli-binary-format raw-in-base64-out \
  --payload '{"ticket_id":"T001","customer":"user@uag.mx","priority_score":85,"description":"Server is down"}' \
  out.json && cat out.json
```

**Validate an invalid ticket (expect `FunctionError`)**

```bash
aws lambda invoke \
  --function-name ticket-validator \
  --cli-binary-format raw-in-base64-out \
  --payload '{"ticket_id":"","customer":"","priority_score":150,"description":""}' \
  out.json && cat out.json
```

**Classify a ticket (expect `"severity": "urgent"`)**

```bash
aws lambda invoke \
  --function-name ticket-classifier \
  --cli-binary-format raw-in-base64-out \
  --payload '{"ticket_id":"T001","customer":"user@uag.mx","priority_score":85,"description":"critical outage","validated":true}' \
  out.json && cat out.json
```

**Route a ticket (expect `"routed": true` and `s3_key`)**

```bash
aws lambda invoke \
  --function-name ticket-router \
  --cli-binary-format raw-in-base64-out \
  --payload '{"ticket_id":"T001","customer":"user@uag.mx","priority_score":85,"description":"outage","validated":true,"severity":"urgent"}' \
  out.json && cat out.json
```

---

### Full pipeline — run all four test cases through Step Functions

This is the definitive end-to-end test. Run all four cases to exercise every branch of the state machine.

```bash
SFN_ARN=$(tofu output -raw state_machine_arn)

# Branch: urgent  — score=90, "unresponsive" keyword
aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "test-urgent-$(date +%s)" \
  --input file://tests/test_urgent.json

# Branch: normal  — score=55, no keywords
aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "test-normal-$(date +%s)" \
  --input file://tests/test_normal.json

# Branch: low     — score=20, "question" keyword
aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "test-low-$(date +%s)" \
  --input file://tests/test_low.json

# Branch: ValidationFailed — empty fields, score=150
aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --name "test-invalid-$(date +%s)" \
  --input file://tests/test_invalid.json
```

---

### Verify S3 routing

After the first three executions succeed, three files should appear in the bucket — one per severity prefix:

```bash
BUCKET=$(tofu output -raw s3_bucket_name)
aws s3 ls s3://$BUCKET --recursive
```

Expected output:

```
2026-05-04 12:00:00    952  urgent/tk-001_20260504T120000Z.json
2026-05-04 12:00:05    921  normal/tk-002_20260504T120005Z.json
2026-05-04 12:00:10    908  low/tk-003_20260504T120010Z.json
```

Download and inspect a file:

```bash
aws s3 cp s3://$BUCKET/urgent/tk-001_<timestamp>.json - | python -m json.tool
```

---

### Check execution status

```bash
# List recent executions
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --query "executions[*].{name:name,status:status}" \
  --output table
```

Expected: three `SUCCEEDED` and one `FAILED` (the invalid ticket).

---

### Check Lambda logs

```bash
aws logs tail /aws/lambda/ticket-validator  --follow
aws logs tail /aws/lambda/ticket-classifier --follow
aws logs tail /aws/lambda/ticket-router     --follow
```

---

## Destroy

Deletes all AWS resources created by this project. The S3 bucket has `force_destroy = true`, so OpenTofu empties it automatically before deleting it.

```bash
tofu destroy
```

---

## Technical Constraints Checklist

| Constraint | Status | Evidence |
|---|---|---|
| Exactly 3 Lambda functions | ✅ | `ticket-validator`, `ticket-classifier`, `ticket-router` |
| All Lambdas in `python3.11` | ✅ | `runtime = "python3.11"` in module `main.tf` |
| Each Lambda receives full event and returns it enriched | ✅ | All three use `{**event, ...new_fields}` |
| Exactly 1 Choice state | ✅ | `RouteByseverity` in `step_function.tf` |
| Choice has 3 branches | ✅ | `StringEquals` for `urgent`, `normal`, `low` + Default |
| At least 1 Fail state | ✅ | 2 Fail states: `ValidationFailed`, `RoutingFailed` |
| At least 1 Succeed state | ✅ | `TicketProcessed` |
| Maximum 7 states total | ✅ | Exactly 7 — no more allowed |
| Deploy with `tofu apply` only | ✅ | No AWS console interaction at any step |
| `tofu destroy` cleans everything | ✅ | `force_destroy = true` on S3, all resources in state |
| Least-privilege IAM | ✅ | No `*` resources; roles scoped to exact ARNs |
| Reusable Lambda module | ✅ | `modules/lambda_function/` instantiated 3 times |
