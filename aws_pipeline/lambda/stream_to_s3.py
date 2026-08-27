import boto3
import json
from datetime import datetime

s3 = boto3.client("s3")

BUCKET = "analytics-bucket-azedine-12345"


def lambda_handler(event, context):

    print(json.dumps(event))

    for record in event["Records"]:

        event_name = record["eventName"]
        dynamodb = record["dynamodb"]

        # INSERT / MODIFY
        if event_name in ["INSERT", "MODIFY"]:
            image = dynamodb.get("NewImage")

        # REMOVE
        elif event_name == "REMOVE":
            image = dynamodb.get("OldImage")

        else:
            continue

        if not image:
            continue

        now = datetime.utcnow()

        key = (
            f"raw/year={now.year}/month={now.month:02d}/day={now.day:02d}/"
            f"{record['eventID']}.json"
        )

        s3.put_object(
            Bucket=BUCKET,
            Key=key,
            Body=json.dumps(image),
            ContentType="application/json"
        )

    return {"statusCode": 200}