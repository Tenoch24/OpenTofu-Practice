# Support Ticket Classifier Pipeline

**Scenario C — Big Data class assignment**  
Infrastructure as Code with **OpenTofu** on AWS: Lambda · Step Functions · S3  
Automated CI/CD via **GitHub Actions** with OIDC (zero long-lived credentials)

---

## What This Does

A support ticket arrives as a JSON event. The pipeline automatically:

1. **Validates** all required fields and score range
2. **Classifies** the ticket as `urgent`, `normal`, or `low` based on score + keywords
3. **Routes** the enriched event to the correct S3 prefix

Everything is deployed with a single `tofu apply` — no console clicks.

---

## Architecture

```
                         ┌──────────────────────────────────────────────┐
  JSON Event             │         AWS Step Functions State Machine       │
  {ticket_id,   ──────►  │                                              │
   customer,             │  ┌──────────────┐    ┌──────────────┐        │
   priority_score,       │  │ ValidateTicket│───►│ClassifyTicket│        │
   description}          │  │   (Lambda L1) │    │  (Lambda L2) │        │
                         │  └──────┬───────┘    └──────┬───────┘        │
                         │         │ error              │                │
                         │         ▼                    ▼                │
                         │  ╔══════════════╗   ┌────────────────┐       │
                         │  ║Validation    ║   │ RouteByseverity│       │
                         │  ║Failed ✗ Fail ║   │   (Choice)     │       │
                         │  ╚══════════════╝   └──┬──────┬──┬───┘       │
                         │                     urgent normal low         │
                         │                        └──────┴──┘           │
                         │                               │               │
                         │                        ┌──────▼───────┐      │
                         │                        │  StoreTicket  │      │
                         │                        │  (Lambda L3)  │      │
                         │                        └──────┬───────┘      │
                         │                               │ error         │
                         │              ┌────────────────┼──────────►   │
                         │              │                ▼          ╔══════════╗
                         │              │       ┌──────────────┐    ║ Routing  ║
                         │              │       │TicketProcessed│    ║Failed ✗ ║
                         │              │       │  ✓ Succeed   │    ╚══════════╝
                         │              │       └──────────────┘          │
                         └─────────────────────────────────────────────────┘
                                                        │
                                                        ▼
                                         s3://ticket-classifier-pipeline/
                                         ├── urgent/  tk-001_....json
                                         ├── normal/  tk-002_....json
                                         └── low/     tk-003_....json
```

---

## Lambda Functions

### L1 — ticket-validator

Reads the raw event and enforces these rules before anything else runs:

| Field | Rule |
|---|---|
| `ticket_id` | Must be present and non-empty |
| `customer` | Must be present and non-empty |
| `priority_score` | Must be a number between 0 and 100 |
| `description` | Must be a non-empty string |

On success it returns the full event enriched with `validated: true` and `validation_message`.  
On any failure it raises `ValueError`, which the Step Functions `Catch` block routes to the `ValidationFailed` Fail state.

### L2 — ticket-classifier

Applies a two-factor classification: **numeric score** and **keyword matching** on the description.

| Condition | Severity |
|---|---|
| `priority_score >= 70` OR any urgent keyword found | `urgent` |
| `priority_score <= 35` AND no urgent keywords AND any low keyword | `low` |
| Everything else | `normal` |

**Urgent keywords:** `urgent`, `emergency`, `critical`, `down`, `outage`, `not working`, `unresponsive`, `broken`, `crash`, `failure`

**Low keywords:** `question`, `inquiry`, `how to`, `documentation`, `feedback`, `suggestion`, `info`, `curious`

Returns the full event enriched with `severity`, `urgent_keywords_matched`, `low_keywords_matched`, and `classification_message`.

### L3 — ticket-router

Reads `severity` and `ticket_id` from the event, then writes the full enriched JSON to:

```
s3://ticket-classifier-pipeline/<severity>/<ticket_id>_<timestamp>.json
```

Returns the full event enriched with `routed: true`, `s3_bucket`, `s3_key`, and `routing_message`.

---

## Step Functions State Machine

The machine has exactly **7 states** (class maximum):

| # | State | Type | Description |
|---|---|---|---|
| 1 | `ValidateTicket` | Task | Invokes L1. On any error → `ValidationFailed` |
| 2 | `ClassifyTicket` | Task | Invokes L2. On any error → `ValidationFailed` |
| 3 | `RouteByseverity` | Choice | Branches on `$.severity` with `StringEquals` for `urgent`, `normal`, `low`. Default also → `StoreTicket` |
| 4 | `StoreTicket` | Task | Invokes L3. On any error → `RoutingFailed` |
| 5 | `TicketProcessed` | Succeed | Terminal success state |
| 6 | `ValidationFailed` | Fail | Terminal failure for L1/L2 errors |
| 7 | `RoutingFailed` | Fail | Terminal failure for L3 errors |

---

## IAM Security Model

Two least-privilege roles are created by `iam.tf`:

**`ticket-classifier-lambda-role`** — assumed by all three Lambda functions
- `AWSLambdaBasicExecutionRole` → write CloudWatch Logs
- Inline policy → `s3:PutObject` and `s3:GetObject` on the tickets bucket only

**`ticket-classifier-sfn-role`** — assumed by the Step Functions state machine
- Inline policy → `lambda:InvokeFunction` on the three Lambda ARNs only

No `*` resources, no admin policies.

---

## Folder Structure

```
.
├── main.tf                          # Providers, S3 bucket, Lambda modules
├── iam.tf                           # IAM roles and policies
├── variables.tf                     # Input variables with defaults
├── outputs.tf                       # state_machine_arn, s3_bucket_name
├── step_function.tf                 # Step Functions state machine definition
│
├── modules/
│   └── lambda_function/             # Reusable module — used 3 times
│       ├── main.tf                  # archive_file data source + aws_lambda_function
│       ├── variables.tf             # function_name, source_dir, role_arn, etc.
│       └── outputs.tf               # function_arn, function_name
│
├── lambdas/
│   ├── validate/lambda_function.py  # L1 — field validation
│   ├── classify/lambda_function.py  # L2 — score + keyword classification
│   └── route/lambda_function.py     # L3 — S3 write
│
├── tests/
│   ├── test_urgent.json             # score=90 + urgent keywords → urgent branch
│   ├── test_normal.json             # score=55 + no keywords    → normal branch
│   ├── test_low.json                # score=20 + low keywords   → low branch
│   └── test_invalid.json            # missing fields + score=150 → ValidationFailed
│
└── .github/
    └── workflows/
        └── opentofu.yml             # CI/CD: plan on PR, apply on push to main
```

---

## Local Deployment

### Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.6.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) configured with credentials that have permissions for Lambda, Step Functions, S3, and IAM

```bash
aws configure        # enter Access Key, Secret, region us-east-1, output json
aws sts get-caller-identity   # verify it works
```

### Deploy

```bash
tofu init
tofu plan
tofu apply
```

`tofu apply` outputs the two values you'll need for testing:

```
state_machine_arn = "arn:aws:states:us-east-1:ACCOUNT:stateMachine:ticket-classifier-pipeline"
s3_bucket_name    = "ticket-classifier-pipeline"
```

### Destroy

```bash
tofu destroy
```

`force_destroy = true` is set on the S3 bucket so all objects are removed automatically — no manual cleanup needed.

---

## Testing

### Option A — Invoke each Lambda directly

Use these commands to test each function in isolation. The `--cli-binary-format raw-in-base64-out` flag is required on AWS CLI v2.

**L1 — ticket-validator (valid input)**
```bash
aws lambda invoke \
  --function-name ticket-validator \
  --payload '{"ticket_id":"T001","customer":"user@example.com","priority_score":85,"description":"Server is down"}' \
  --cli-binary-format raw-in-base64-out \
  response.json && cat response.json
```
Expected: `"validated": true`

**L1 — ticket-validator (invalid input)**
```bash
aws lambda invoke \
  --function-name ticket-validator \
  --payload '{"ticket_id":"","customer":"","priority_score":150,"description":""}' \
  --cli-binary-format raw-in-base64-out \
  response.json && cat response.json
```
Expected: `FunctionError` with `"Validation failed: ..."`

**L2 — ticket-classifier**
```bash
aws lambda invoke \
  --function-name ticket-classifier \
  --payload '{"ticket_id":"T001","customer":"user@example.com","priority_score":85,"description":"critical outage","validated":true}' \
  --cli-binary-format raw-in-base64-out \
  response.json && cat response.json
```
Expected: `"severity": "urgent"`

**L3 — ticket-router**
```bash
aws lambda invoke \
  --function-name ticket-router \
  --payload '{"ticket_id":"T001","customer":"user@example.com","priority_score":85,"description":"outage","validated":true,"severity":"urgent"}' \
  --cli-binary-format raw-in-base64-out \
  response.json && cat response.json
```
Expected: `"routed": true` and an `s3_key` like `urgent/T001_20260504T....json`

### Option B — Run the full pipeline through Step Functions

This is the real end-to-end test. All four branches covered:

```bash
SFN_ARN=$(tofu output -raw state_machine_arn)

# Urgent branch — score=90 + urgent keywords
aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_urgent.json

# Normal branch — score=55 + no keywords
aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_normal.json

# Low branch — score=20 + low keywords
aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_low.json

# ValidationFailed branch — empty fields + score=150
aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_invalid.json
```

### Verify S3 routing

```bash
BUCKET=$(tofu output -raw s3_bucket_name)
aws s3 ls s3://$BUCKET --recursive
```

Expected output:
```
2026-05-04 ...  urgent/tk-001_20260504T....json
2026-05-04 ...  normal/tk-002_20260504T....json
2026-05-04 ...  low/tk-003_20260504T....json
```

### Check Lambda logs

```bash
aws logs tail /aws/lambda/ticket-validator   --follow
aws logs tail /aws/lambda/ticket-classifier  --follow
aws logs tail /aws/lambda/ticket-router      --follow
```

---

## CI/CD with GitHub Actions

The workflow at `.github/workflows/opentofu.yml` runs automatically:

| Event | Job name | Steps |
|---|---|---|
| Pull request → `main` | `plan` | init → validate → plan |
| Push → `main` | `apply` | init → validate → plan → apply |

Authentication uses **OIDC** — GitHub signs a JWT that AWS verifies. No access keys, no secrets stored in GitHub.

### One-time AWS setup (do this once per AWS account)

**Step 1 — Create the OIDC identity provider**

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

**Step 2 — Create the IAM role with a trust policy scoped to your repo**

Replace `YOUR_ACCOUNT_ID` and `YOUR_GITHUB_USER/YOUR_REPO`:

```bash
aws iam create-role \
  --role-name ticket-classifier-gha \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USER/YOUR_REPO:*"
        }
      }
    }]
  }'
```

**Step 3 — Attach the required policies to the role**

```bash
aws iam attach-role-policy --role-name ticket-classifier-gha \
  --policy-arn arn:aws:iam::aws:policy/AWSLambda_FullAccess

aws iam attach-role-policy --role-name ticket-classifier-gha \
  --policy-arn arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess

aws iam attach-role-policy --role-name ticket-classifier-gha \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy --role-name ticket-classifier-gha \
  --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

aws iam attach-role-policy --role-name ticket-classifier-gha \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
```

**Step 4 — Update the workflow with the role ARN**

In `.github/workflows/opentofu.yml`, set:

```yaml
AWS_ROLE: "arn:aws:iam::YOUR_ACCOUNT_ID:role/ticket-classifier-gha"
```

After that, every push to `main` triggers a full deploy automatically.

---

## Technical Constraints Checklist

| Constraint | Status | Detail |
|---|---|---|
| Exactly 3 Lambda functions | ✅ | `ticket-validator`, `ticket-classifier`, `ticket-router` |
| Exactly 1 Choice state | ✅ | `RouteByseverity` with `StringEquals` on `$.severity` |
| Choice has 3 branches | ✅ | `urgent` / `normal` / `low` + Default |
| At least 1 Fail state | ✅ | 2 Fail states: `ValidationFailed`, `RoutingFailed` |
| At least 1 Succeed state | ✅ | `TicketProcessed` |
| Max 7 total states | ✅ | Exactly 7 |
| Deploy with `tofu apply` only | ✅ | No console interaction required |
| `tofu destroy` cleans everything | ✅ | `force_destroy = true` on S3 |
| Lambdas receive full event and return it enriched | ✅ | All three use `{**event, ...new_fields}` |
| Reusable module for Lambda | ✅ | `modules/lambda_function/` used 3 times |
| CI/CD without long-lived credentials | ✅ | GitHub Actions + OIDC, zero secrets stored |
