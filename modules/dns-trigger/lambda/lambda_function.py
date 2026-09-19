import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ["REGION"]
CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]
START_TOKEN = os.environ.get("START_TOKEN", "")


def _response(status_code, body):
    """Function URL invocations use API Gateway payload format 2.0 — a
    plain return value isn't interpreted as an HTTP response without this
    shape. CloudWatch Logs subscription invocations are async and ignore
    the return value entirely, so it's safe to always return this either
    way rather than branch on caller."""
    return {"statusCode": status_code, "body": body}


def lambda_handler(event, context):
    """Scales the Minecraft ECS service up from zero.

    Invoked two ways: a CloudWatch Logs subscription filter (the DNS
    trigger — async, no meaningful event fields) and, when
    enable_start_api is on, a public Lambda Function URL (sync HTTP, no
    AWS auth on the URL itself, so it's gated by a matching ?token= query
    param instead). Both converge on the same check-then-act scale-up.

    CloudWatch Logs subscription filters invoke asynchronously and can retry
    or redeliver, and concurrent DNS lookups can trigger overlapping
    invocations — so this must tolerate running more than once for what's
    logically a single wake-up. update_service(desiredCount=1) is a plain
    assignment, not an increment, so re-running it (with the pre-check or
    without) can't scale past 1; the desired==0 check just avoids a
    redundant API call on the common path where the server is already up.
    """
    if "requestContext" in event:  # Function URL invocation, not CloudWatch Logs
        token = (event.get("queryStringParameters") or {}).get("token")
        if not START_TOKEN or token != START_TOKEN:
            return _response(403, "Forbidden")

    ecs = boto3.client("ecs", region_name=REGION)

    try:
        services = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])["services"]
    except ClientError as e:
        print(f"describe_services failed for {SERVICE} on {CLUSTER}: {e}")
        raise

    if not services:
        raise RuntimeError(f"Service {SERVICE} not found on cluster {CLUSTER}")

    desired = services[0]["desiredCount"]

    if desired == 0:
        ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)
        print("Updated desiredCount to 1")
        return _response(200, "Starting the server — give it a minute or two.")

    print("desiredCount already at 1")
    return _response(200, "Already running.")
