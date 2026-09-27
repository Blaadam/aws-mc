import os
from datetime import datetime, timezone

import boto3

TOPIC_ARN = os.environ["TOPIC_ARN"]
CONTAINER_NAME = os.environ["CONTAINER_NAME"]
# Must match CRASH_SUBJECT in ../lambda/lambda_function.py — the Discord
# relay keys its card style off this exact subject.
SUBJECT = "Minecraft server crashed"

sns = boto3.client("sns")


def lambda_handler(event, context):
    """Turns an EventBridge "ECS Task State Change" event into a
    notification on the same SNS topic the watchdog publishes to, so it
    fans out to email/Discord exactly like the online/shutting-down ones.

    The EventBridge rule only matches the minecraft-server container being
    STOPPED while the task's desiredStatus is still RUNNING. The watchdog
    sidecar is the only essential container, so the task keeps running
    after Minecraft dies, and ECS reports the service as healthy while
    nobody can connect. A normal scale-down or Spot interruption flips
    desiredStatus to STOPPED *before* the containers stop, so it never
    matches.

    Why a Lambda rather than EventBridge -> SNS directly: the topic is
    encrypted with the AWS-managed alias/aws/sns key, and EventBridge can't
    publish to a topic encrypted with an AWS-managed key (it needs a
    customer-managed key, a recurring cost this project avoids)."""
    detail = event["detail"]
    container = next(c for c in detail["containers"] if c["name"] == CONTAINER_NAME)
    task_id = detail["taskArn"].rsplit("/", 1)[-1]

    exit_code = container.get("exitCode", "unknown")
    reason = container.get("reason")

    uptime = ""
    if detail.get("startedAt"):
        started = datetime.fromisoformat(detail["startedAt"].replace("Z", "+00:00"))
        minutes = (datetime.now(timezone.utc) - started).total_seconds() / 60
        uptime = f" {minutes:.0f} min after the task started"

    lines = [
        f"The Minecraft server process stopped unexpectedly (exit code {exit_code}){uptime}. "
        "Players can't connect. The watchdog will scale the service back to zero on its own.",
    ]
    if reason:
        lines.append(f"Reason: {reason}")
    lines.append(f"Task: {task_id}")
    lines.append(
        "Check the server log with `just logs-minecraft` (needs debug = true). "
        "A crash within the first minute is usually a download failing at startup, "
        "e.g. Modrinth being down — see the README's Troubleshooting section."
    )

    sns.publish(TopicArn=TOPIC_ARN, Subject=SUBJECT, Message="\n".join(lines))
