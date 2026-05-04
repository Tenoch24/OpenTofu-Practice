# ─────────────────────────────────────────────────────────────
#  Step Function — Scenario C: Support Ticket Classifier
#
#  States (7 total — maximum allowed):
#    1. ValidateTicket   Task
#    2. ClassifyTicket   Task
#    3. RouteByseverity  Choice  (3 branches: urgent / normal / low)
#    4. StoreTicket      Task
#    5. TicketProcessed  Succeed
#    6. ValidationFailed Fail
#    7. RoutingFailed    Fail
# ─────────────────────────────────────────────────────────────

resource "aws_sfn_state_machine" "ticket_pipeline" {
  name     = "ticket-classifier-pipeline"
  role_arn = aws_iam_role.sfn_exec.arn

  definition = jsonencode({
    Comment = "Scenario C – Support Ticket Classifier"
    StartAt = "ValidateTicket"

    States = {

      # ── State 1: Validate ────────────────────────────────────
      ValidateTicket = {
        Type     = "Task"
        Resource = module.lambda_validate.function_arn
        Next     = "ClassifyTicket"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "ValidationFailed"
        }]
      }

      # ── State 2: Classify ────────────────────────────────────
      ClassifyTicket = {
        Type     = "Task"
        Resource = module.lambda_classify.function_arn
        Next     = "RouteByseverity"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "ValidationFailed"
        }]
      }

      # ── State 3: Choice (1 required, 3 branches) ─────────────
      RouteByseverity = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.severity"
            StringEquals = "urgent"
            Next         = "StoreTicket"
          },
          {
            Variable     = "$.severity"
            StringEquals = "normal"
            Next         = "StoreTicket"
          },
          {
            Variable     = "$.severity"
            StringEquals = "low"
            Next         = "StoreTicket"
          }
        ]
        Default = "StoreTicket"
      }

      # ── State 4: Route / store in S3 ─────────────────────────
      StoreTicket = {
        Type     = "Task"
        Resource = module.lambda_route.function_arn
        Next     = "TicketProcessed"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "RoutingFailed"
        }]
      }

      # ── State 5: Succeed ──────────────────────────────────────
      TicketProcessed = {
        Type    = "Succeed"
        Comment = "Ticket classified and stored successfully"
      }

      # ── State 6: Fail – validation / classification ───────────
      ValidationFailed = {
        Type  = "Fail"
        Error = "ValidationError"
        Cause = "Ticket failed validation or classification"
      }

      # ── State 7: Fail – S3 routing ────────────────────────────
      RoutingFailed = {
        Type  = "Fail"
        Error = "RoutingError"
        Cause = "Failed to store ticket in S3"
      }

    }
  })

  tags = { Project = var.project_name }
}
