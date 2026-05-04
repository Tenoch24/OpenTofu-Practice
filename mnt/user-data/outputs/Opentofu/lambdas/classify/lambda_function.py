import json


# Keywords that raise severity toward "urgent"
URGENT_KEYWORDS = [
    "urgent", "emergency", "critical", "down", "outage",
    "not working", "unresponsive", "broken", "crash", "failure",
]

# Keywords that lower severity toward "low"
LOW_KEYWORDS = [
    "question", "inquiry", "how to", "documentation",
    "feedback", "suggestion", "info", "curious",
]


def lambda_handler(event, context):
    """
    L2 - Classify
    Reads:  priority_score, description  (added by L1: validated)
    Adds:   severity ("urgent" | "normal" | "low"),
            urgent_keywords_matched (int),
            low_keywords_matched (int),
            classification_message (str)

    Classification logic:
      - score >= 70  OR  any urgent keyword found  => "urgent"
      - score <= 35  AND no urgent keyword  AND any low keyword => "low"
      - everything else                            => "normal"
    """
    score = event.get("priority_score", 0)
    description = event.get("description", "").lower()

    urgent_hits = sum(1 for kw in URGENT_KEYWORDS if kw in description)
    low_hits    = sum(1 for kw in LOW_KEYWORDS    if kw in description)

    if score >= 70 or urgent_hits > 0:
        severity = "urgent"
    elif score <= 35 and urgent_hits == 0 and low_hits > 0:
        severity = "low"
    else:
        severity = "normal"

    return {
        **event,
        "severity": severity,
        "urgent_keywords_matched": urgent_hits,
        "low_keywords_matched": low_hits,
        "classification_message": f"Ticket classified as '{severity}' "
                                  f"(score={score}, urgent_kw={urgent_hits}, low_kw={low_hits})",
    }
