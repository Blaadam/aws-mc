import json
import os
import urllib.request

WEBHOOK_URL = os.environ["WEBHOOK_URL"]
CUSTOM_MESSAGE = os.environ.get("CUSTOM_MESSAGE", "")
START_API_URL = os.environ.get("START_API_URL", "")
ICON_URL = os.environ.get("ICON_URL", "")

TEXT_DISPLAY = 10
ACTION_ROW = 1
BUTTON = 2
SECTION = 9
THUMBNAIL = 11
SEPARATOR = 14
CONTAINER = 17
LINK_STYLE = 5
IS_COMPONENTS_V2 = 1 << 15

GREEN = 0x57F287
RED = 0xED4245


def lambda_handler(event, context):
    """Relays the watchdog's SNS notification (server online / shutting
    down) to a Discord webhook as a Components V2 card: a color-accented
    Container with the server icon as a thumbnail, and — on the shutdown
    message only, when enable_start_api created a URL to point at — a
    one-tap restart button. One invocation per SNS record, same as the
    email subscription this fans out alongside."""
    for record in event["Records"]:
        message = record["Sns"]["Message"]
        # Matches the watchdog's own hardcoded wording (doctorray117/
        # minecraft-ondemand's watchdog.sh), not something this project
        # controls.
        is_shutdown = "Shutting down" in message

        text = [{"type": TEXT_DISPLAY, "content": "### " + ("🔴 Server shutting down" if is_shutdown else "🟢 Server online")}]
        if CUSTOM_MESSAGE:
            text.append({"type": TEXT_DISPLAY, "content": CUSTOM_MESSAGE})
        text.append({"type": TEXT_DISPLAY, "content": message})

        # A Section's accessory puts the icon beside the text, like an
        # embed thumbnail — only possible with 1-3 Text Displays, which
        # `text` always is (title + optional custom line + message).
        if ICON_URL:
            body_component = {
                "type": SECTION,
                "components": text,
                "accessory": {"type": THUMBNAIL, "media": {"url": ICON_URL}},
            }
            container_children = [body_component]
        else:
            container_children = text

        if is_shutdown and START_API_URL:
            container_children.append({"type": SEPARATOR})
            container_children.append(
                {
                    "type": ACTION_ROW,
                    "components": [
                        {
                            "type": BUTTON,
                            "style": LINK_STYLE,
                            "label": "Restart server",
                            "url": START_API_URL,
                        }
                    ],
                }
            )

        payload = {
            "flags": IS_COMPONENTS_V2,
            "components": [
                {
                    "type": CONTAINER,
                    "accent_color": RED if is_shutdown else GREEN,
                    "components": container_children,
                }
            ],
        }
        body = json.dumps(payload).encode("utf-8")

        # with_components=true: this is a plain channel webhook, not one
        # owned by a bot application — Discord silently drops the
        # components field on Execute Webhook without this, even though
        # link buttons need no interaction handler to work.
        request = urllib.request.Request(
            f"{WEBHOOK_URL}?with_components=true",
            data=body,
            headers={
                "Content-Type": "application/json",
                # Discord's Cloudflare front rejects urllib's default
                # "Python-urllib/x.y" User-Agent as bot-like (403,
                # Cloudflare error 1010) — any real-looking value clears it.
                "User-Agent": "aws-mc-discord-notify/1.0",
            },
            method="POST",
        )
        try:
            # Discord returns 204 No Content on success.
            urllib.request.urlopen(request)
        except urllib.error.HTTPError as e:
            print(f"Discord webhook POST failed: {e.code} {e.read().decode('utf-8', 'replace')}")
            raise
