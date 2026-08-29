import boto3
import json
import os
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]  # corrigé : plus de valeur en dur


def lambda_handler(event, context):
    processed = 0
    failed = 0

    for record in event["Records"]:
        try:
            event_name = record["eventName"]
            dynamodb = record["dynamodb"]

            if event_name in ("INSERT", "MODIFY"):
                image = dynamodb.get("NewImage")
            elif event_name == "REMOVE":
                image = dynamodb.get("OldImage")
            else:
                continue

            if not image:
                continue

            now = datetime.now(timezone.utc)  # corrigé : utcnow() déprécié

            key = (
                f"raw/year={now.year}/month={now.month:02d}/day={now.day:02d}/"
                f"{record['eventID']}.json"
            )

            s3.put_object(
                Bucket=BUCKET,
                Key=key,
                Body=json.dumps(image),
                ContentType="application/json",
            )
            processed += 1

        except Exception:
            # une erreur sur un record n'interrompt plus tout le batch
            failed += 1
            logger.exception(
                "Échec de traitement du record eventID=%s",
                record.get("eventID", "UNKNOWN"),
            )

    logger.info("Batch traité : %s ok, %s échecs", processed, failed)

    if failed and not processed:
        # tout le batch a échoué -> on laisse Lambda retenter (DLQ/bisect prendront le relais)
        raise RuntimeError(f"{failed} records en échec sur ce batch")

    return {
        "statusCode": 200,
        "body": json.dumps({"processed": processed, "failed": failed}),
    }
