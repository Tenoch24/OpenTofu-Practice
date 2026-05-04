# Support Ticket Classifier Pipeline

**Scenario C** — Big Data class assignment  
Deployed with OpenTofu on AWS (Lambda + Step Functions + S3)

---

## What This Pipeline Does

This project implements an automated support-ticket triage system. When a ticket arrives, it passes through three Lambda functions orchestrated by an AWS Step Functions state machine. The pipeline classifies each ticket as `urgent`, `normal`, or `low`, then stores the enriched event as a JSON file in the corresponding S3 prefix — all without any manual console interaction.

### Lambda Functions

| # | Name | Role |
|---|------|------|
| L1 | `ticket-validator` | Validates that `priority_score` is a number between 0–100 and that `description` is non-empty. On failure, execution goes directly to the `ValidationFailed` Fail state. |
| L2 | `ticket-classifier` | Determines `severity` by combining the numeric `priority_score` with keyword detection on the `description`. Words like `urgent`, `down`, `outage`, and `critical` raise severity; words like `question`, `feedback`, and `how to` lower it. Score ≥ 70 or any urgent keyword → `urgent`. Score ≤ 35 with no urgent keywords but at least one low keyword → `low`. Everything else → `normal`. |
| L3 | `ticket-router` | Reads `severity` and writes the full enriched event to `s3://<bucket>/<severity>/<ticket_id>_<timestamp>.json`. |

Every Lambda receives the complete `event` object and returns it with additional fields — matching the class contract.

### Step Function State Machine

The machine has exactly **7 states** (the allowed maximum):

```
[ValidateTicket] → [ClassifyTicket] → [RouteByseverity: Choice]
                                             │         │         │
                                          urgent    normal      low
                                             └────────┴──────────┘
                                                      │
                                               [StoreTicket]
                                                      │
                                            [TicketProcessed ✓ Succeed]

Any Lambda error → [ValidationFailed ✗ Fail] or [RoutingFailed ✗ Fail]
```

### S3 Output Structure

```
s3://ticket-classifier-pipeline/
├── urgent/   tk-001_20240501T120000Z.json
├── normal/   tk-002_20240501T120100Z.json
└── low/      tk-003_20240501T120200Z.json
```

---

## Deployment

### Prerequisites
- [OpenTofu](https://opentofu.org/) >= 1.6.0
- AWS CLI configured (`aws configure`)

### Deploy
```bash
tofu init
tofu plan
tofu apply
```

### Run a test from the CLI (step 9)
```bash
# Get the State Machine ARN from outputs
SFN_ARN=$(tofu output -raw state_machine_arn)

# Start an execution with each test file
aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_urgent.json

aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_normal.json

aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --input file://tests/test_low.json
```

### Verify S3 routing (step 10)
```bash
BUCKET=$(tofu output -raw s3_bucket_name)
aws s3 ls s3://$BUCKET --recursive
```

Expected output:
```
urgent/tk-001_....json
normal/tk-002_....json
low/tk-003_....json
```

### Destroy (before submitting — step 12)
```bash
tofu destroy
```
`force_destroy = true` is set on the S3 bucket, so all objects are removed automatically.

---

## Technical Constraints Checklist

| Constraint | Implemented |
|---|---|
| Exactly 3 Lambdas | ticket-validator, ticket-classifier, ticket-router |
| Exactly 1 Choice state | RouteByseverity |
| Choice has 3 branches | urgent / normal / low via StringEquals |
| Min 1 Fail + 1 Succeed | 2 x Fail + 1 x Succeed |
| Max 7 total states | Exactly 7 |
| Deploy with tofu apply only | No console clicks |
| tofu destroy cleans everything | force_destroy = true on S3 |
| Folder structure matches class | modules/lambda_function/, lambdas/, step_function.tf |
| No extra services | Lambda + Step Functions + S3 + IAM only |
| Lambdas receive full event and return it enriched | {**event, ...new_fields} in all 3 |

---

## Folder Structure

```
.
├── main.tf                         # Provider, S3, Lambda modules
├── iam.tf                          # IAM roles (do not modify)
├── variables.tf                    # Input variables (do not modify)
├── outputs.tf                      # Output values
├── step_function.tf                # Step Function definition
├── modules/
│   └── lambda_function/            # Reusable module (do not modify)
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── lambdas/
│   ├── validate/lambda_function.py # L1 - Validation
│   ├── classify/lambda_function.py # L2 - Classification
│   └── route/lambda_function.py    # L3 - S3 Routing
└── tests/
    ├── test_urgent.json            # Branch: urgent (score=90, urgent keywords)
    ├── test_normal.json            # Branch: normal (score=55, no keywords)
    ├── test_low.json               # Branch: low (score=20, low keywords)
    └── test_invalid.json           # Triggers ValidationFailed Fail state
```
