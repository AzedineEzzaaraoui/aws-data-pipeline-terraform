import boto3
import json
import os

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]


def lambda_handler(event, context):

    response = s3.list_objects_v2(
        Bucket=BUCKET,
        Prefix="raw/"
    )

    results = {}

    for obj in response.get("Contents", []):

        file_obj = s3.get_object(
            Bucket=BUCKET,
            Key=obj["Key"]
        )

        body = file_obj["Body"].read().decode("utf-8")
        data = json.loads(body)

        # DynamoDB format fix
        product = data.get("product_id", {}).get("S", "UNKNOWN")

        results[product] = results.get(product, 0) + 1

    # write aggregated result
    s3.put_object(
        Bucket=BUCKET,
        Key="processed/cart_summary.json",
        Body=json.dumps(results),
        ContentType="application/json"
    )

    print("Processed data written successfully")

    return {
        "statusCode": 200,
        "body": json.dumps(results)
    }