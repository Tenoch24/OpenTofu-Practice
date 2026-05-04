import json


def lambda_handler(event, context):
    """
    L1 - Validate
    Reads:  priority_score, description, ticket_id, customer
    Adds:   validated (bool), validation_message (str)
    Raises: ValueError if any field is invalid (-> Fail state)
    """
    errors = []

    # --- ticket_id ---
    if not event.get("ticket_id"):
        errors.append("Missing required field: ticket_id")

    # --- customer ---
    if not event.get("customer"):
        errors.append("Missing required field: customer")

    # --- priority_score: must be numeric 0-100 ---
    score = event.get("priority_score")
    if score is None:
        errors.append("Missing required field: priority_score")
    elif not isinstance(score, (int, float)):
        errors.append("priority_score must be a number")
    elif not (0 <= score <= 100):
        errors.append("priority_score must be between 0 and 100")

    # --- description: must be non-empty string ---
    description = event.get("description", "")
    if not isinstance(description, str) or not description.strip():
        errors.append("description must be a non-empty string")

    if errors:
        raise ValueError(f"Validation failed: {'; '.join(errors)}")

    # Enrich and return the full event
    return {
        **event,
        "validated": True,
        "validation_message": "All fields passed validation",
    }
