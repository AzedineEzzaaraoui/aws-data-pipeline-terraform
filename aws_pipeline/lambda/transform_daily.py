import boto3
import json
import os
import logging
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]


def lambda_handler(event, context):
    # Permet de rejouer une date précise via l'event EventBridge
    # (ex: {"date": "2026-08-27"}). Par défaut : la veille.
    target_date_str = event.get("date") if event else None

    if target_date_str:
        target_date = datetime.strptime(target_date_str, "%Y-%m-%d").date()
    else:
        target_date = (datetime.now(timezone.utc) - timedelta(days=1)).date()

    prefix = (
        f"raw/year={target_date.year}/"
        f"month={target_date.month:02d}/"
        f"day={target_date.day:02d}/"
    )

    logger.info("Traitement de la partition : %s", prefix)

    results = {}
    processed = 0
    failed = 0

    paginator = s3.get_paginator("list_objects_v2")
    # corrigé : pagination gérée au lieu d'un seul appel plafonné à 1000 objets
    for page in paginator.paginate(Bucket=BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            try:
                file_obj = s3.get_object(Bucket=BUCKET, Key=obj["Key"])
                body = file_obj["Body"].read().decode("utf-8")
                data = json.loads(body)

                product = data.get("product_id", {}).get("S", "UNKNOWN")
                results[product] = results.get(product, 0) + 1
                processed += 1

            except Exception:
                # un fichier corrompu ne bloque plus tout le job
                failed += 1
                logger.exception("Échec de lecture de l'objet %s", obj["Key"])

    output_key = (
        f"processed/year={target_date.year}/"
        f"month={target_date.month:02d}/"
        f"day={target_date.day:02d}/summary.json"
    )

    s3.put_object(
        Bucket=BUCKET,
        Key=output_key,
        Body=json.dumps(results),
        ContentType="application/json",
    )

    logger.info(
        "Partition %s traitée : %s fichiers ok, %s échecs, résultat -> %s",
        prefix,
        processed,
        failed,
        output_key,
    )

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "date": str(target_date),
                "processed": processed,
                "failed": failed,
                "output": output_key,
            }
        ),
    }
