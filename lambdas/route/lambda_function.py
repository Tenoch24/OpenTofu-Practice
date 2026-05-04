import json
import boto3
import os
from datetime import datetime, timezone


s3 = boto3.client("s3")
BUCKET_NAME = os.environ["BUCKET_NAME"]


def lambda_handler(event, context):
    """
    L3 - Route
    Reads:  severity ("urgent" | "normal" | "low"), ticket_id
    Adds:   s3_bucket, s3_key, routed (bool), routing_message (str)

    Stores the full enriched event JSON at:
      s3://<bucket>/<severity>/<ticket_id>_<timestamp>.json
    """
    severity  = event.get("severity", "normal")
    ticket_id = event.get("ticket_id", "unknown")
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    s3_key = f"{severity}/{ticket_id}_{timestamp}.json"

    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps(event, indent=2),
        ContentType="application/json",
    )

    return {
        **event,
        "routed": True,
        "s3_bucket": BUCKET_NAME,
        "s3_key": s3_key,
        "routing_message": f"Stored at s3://{BUCKET_NAME}/{s3_key}",
    }
