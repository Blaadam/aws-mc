locals {
  # Only the *presence* of a webhook URL, not the URL itself — wrapped in
  # nonsensitive() so this boolean can safely drive counts and the topic_arn
  # output without tainting them as sensitive too. discord_webhook_url's
  # actual value is still only ever read where it needs to be (the Lambda's
  # environment block below).
  discord_enabled = nonsensitive(var.discord_webhook_url != "")
}

resource "aws_sns_topic" "this" {
  count = var.sns_email_address != "" || local.discord_enabled ? 1 : 0
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
