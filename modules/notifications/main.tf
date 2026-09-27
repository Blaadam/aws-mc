locals {
  # Only the *presence* of a webhook URL, not the URL itself — wrapped in
  # nonsensitive() so this boolean can safely drive counts and the topic_arn
  # output without tainting them as sensitive too. discord_webhook_url's
  # actual value is still only ever read where it needs to be (the Lambda's
  # environment block below).
  discord_enabled = nonsensitive(var.discord_webhook_url != "")
  topic_enabled   = var.sns_email_address != "" || local.discord_enabled
}

resource "aws_sns_topic" "this" {
  count = local.topic_enabled ? 1 : 0
  name  = "${var.project_name}-notifications"
  # AWS's own managed key — free, no per-request KMS charges, unlike a
  # customer-managed key. Nothing sensitive goes through this topic anyway.
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.sns_email_address != "" ? 1 : 0

  topic_arn = aws_sns_topic.this[0].arn
  protocol  = "email"
  endpoint  = var.sns_email_address
}

# --- Discord relay (off unless discord_webhook_url is set) -------------

data "archive_file" "discord" {
  count = local.discord_enabled ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/dist/discord.zip"
}

resource "aws_iam_role" "discord" {
  count = local.discord_enabled ? 1 : 0

  name = "${var.project_name}-discord-notify"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "discord_logs" {
  count = local.discord_enabled ? 1 : 0

  role       = aws_iam_role.discord[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "discord" {
  count = local.discord_enabled ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-discord-notify"
  retention_in_days = var.log_retention_days
  log_group_class   = "INFREQUENT_ACCESS"
}

resource "aws_lambda_function" "discord" {
  count = local.discord_enabled ? 1 : 0

  function_name    = "${var.project_name}-discord-notify"
  role             = aws_iam_role.discord[0].arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.discord[0].output_path
  source_code_hash = data.archive_file.discord[0].output_base64sha256

  environment {
    variables = {
      WEBHOOK_URL    = var.discord_webhook_url
      CUSTOM_MESSAGE = var.discord_message
      START_API_URL  = var.start_api_url
      ICON_URL       = var.icon_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.discord]
}

resource "aws_lambda_permission" "discord_sns" {
  count = local.discord_enabled ? 1 : 0

  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.this[0].arn
}

resource "aws_sns_topic_subscription" "discord" {
  count = local.discord_enabled ? 1 : 0

  topic_arn = aws_sns_topic.this[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord[0].arn

  depends_on = [aws_lambda_permission.discord_sns]
}

# --- Crash notification (on whenever the topic exists) -----------------
#
# The watchdog only ever says "online" or "shutting down". If the
# minecraft-server container itself dies (bad config, an OOM kill, or a
# failed download at startup, as when Modrinth's API timed out on
# 2026-09-26), the task keeps running because only the watchdog is
# essential. ECS then shows the service as healthy, and nothing tells you
# until the watchdog gives up and scales to zero. This catches that
# moment from the ECS event stream instead.
#
# EventBridge -> Lambda -> SNS rather than EventBridge -> SNS: the topic
# uses the AWS-managed alias/aws/sns key, which EventBridge can't publish
# to. Moving to a customer-managed key would cost ~$1/month for no other
# benefit.

data "archive_file" "crash" {
  count = local.topic_enabled ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/crash_lambda"
  output_path = "${path.module}/dist/crash.zip"
}

resource "aws_iam_role" "crash" {
  count = local.topic_enabled ? 1 : 0

  name = "${var.project_name}-crash-notify"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "crash_logs" {
  count = local.topic_enabled ? 1 : 0

  role       = aws_iam_role.crash[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "crash_publish" {
  count = local.topic_enabled ? 1 : 0

  name = "sns-publish"
  role = aws_iam_role.crash[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.this[0].arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "crash" {
  count = local.topic_enabled ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-crash-notify"
  retention_in_days = var.log_retention_days
  log_group_class   = "INFREQUENT_ACCESS"
}

resource "aws_lambda_function" "crash" {
  count = local.topic_enabled ? 1 : 0

  function_name    = "${var.project_name}-crash-notify"
  role             = aws_iam_role.crash[0].arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.crash[0].output_path
  source_code_hash = data.archive_file.crash[0].output_base64sha256

  environment {
    variables = {
      TOPIC_ARN      = aws_sns_topic.this[0].arn
      CONTAINER_NAME = var.minecraft_container_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.crash]
}

# Matches only "minecraft-server container STOPPED while the task is still
# meant to be RUNNING". A normal scale-down or Spot interruption sets the
# task's desiredStatus to STOPPED before any container stops, so those
# never match. EventBridge matches array-of-object fields element-wise
# (name and lastStatus may come from different containers), but the
# watchdog is essential: if it stopped, desiredStatus would already be
# STOPPED, so any STOPPED container here is minecraft-server.
resource "aws_cloudwatch_event_rule" "crash" {
  count = local.topic_enabled ? 1 : 0

  name        = "${var.project_name}-server-crashed"
  description = "minecraft-server container stopped while its task is still desired RUNNING"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn    = [var.ecs_cluster_arn]
      group         = ["service:${var.ecs_service_name}"]
      desiredStatus = ["RUNNING"]
      containers = {
        name       = [var.minecraft_container_name]
        lastStatus = ["STOPPED"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "crash" {
  count = local.topic_enabled ? 1 : 0

  rule = aws_cloudwatch_event_rule.crash[0].name
  arn  = aws_lambda_function.crash[0].arn
}

resource "aws_lambda_permission" "crash_events" {
  count = local.topic_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.crash[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.crash[0].arn
}
