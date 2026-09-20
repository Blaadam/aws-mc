import json
import os
import urllib.request

WEBHOOK_URL = os.environ["WEBHOOK_URL"]
CUSTOM_MESSAGE = os.environ.get("CUSTOM_MESSAGE", "")


def lambda_handler(event, context):
    """Relays the watchdog's SNS notification (server online / shutting
    down) to a Discord webhook. One invocation per SNS record, same as the
    email subscription this fans out alongside."""
    for record in event["Records"]:
        message = record["Sns"]["Message"]
        content = f"{CUSTOM_MESSAGE}\n{message}" if CUSTOM_MESSAGE else message

        body = json.dumps({"content": content}).encode("utf-8")
        request = urllib.request.Request(
            WEBHOOK_URL,
            data=body,
            # Discord's Cloudflare front rejects urllib's default
            # "Python-urllib/x.y" User-Agent as bot-like (403, Cloudflare
            # error 1010) — any real-looking value clears it.
            headers={"Content-Type": "application/json", "User-Agent": "aws-mc-discord-notify/1.0"},
            method="POST",
        )
        try:
            # Discord returns 204 No Content on success.
            urllib.request.urlopen(request)
        except urllib.error.HTTPError as e:
            print(f"Discord webhook POST failed: {e.code} {e.read().decode('utf-8', 'replace')}")
            raise
