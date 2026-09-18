import os

import boto3

REGION = os.environ["REGION"]
CLUSTER = os.environ["CLUSTER"]
SERVICE = os.environ["SERVICE"]


def lambda_handler(event, context):
    """Scales the Minecraft ECS service up from zero when a DNS query for it comes in."""
    ecs = boto3.client("ecs", region_name=REGION)
    response = ecs.describe_services(cluster=CLUSTER, services=[SERVICE])
    desired = response["services"][0]["desiredCount"]

    if desired == 0:
        ecs.update_service(cluster=CLUSTER, service=SERVICE, desiredCount=1)
        print("Updated desiredCount to 1")
    else:
        print("desiredCount already at 1")
