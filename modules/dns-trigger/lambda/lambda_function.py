import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ["REGION"]
CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]


def lambda_handler(event, context):
    """Scales the Minecraft ECS service up from zero when a DNS query for it comes in.

    CloudWatch Logs subscription filters invoke asynchronously and can retry
    or redeliver, and concurrent DNS lookups can trigger overlapping
    invocations — so this must tolerate running more than once for what's
    logically a single wake-up. update_service(desiredCount=1) is a plain
    assignment, not an increment, so re-running it (with the pre-check or
    without) can't scale past 1; the desired==0 check just avoids a
    redundant API call on the common path where the server is already up.
    """
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
    else:
        print("desiredCount already at 1")
