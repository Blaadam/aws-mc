locals {
  subdomain = "${var.subdomain_part}.${var.domain_name}"
}

data "aws_region" "current" {}

# Allow Route 53 to write DNS query logs to CloudWatch Logs. This is an
# account-wide, region-specific resource policy (Route 53 query logging is
# only supported with a CloudWatch Logs destination in us-east-1) — if
# another project already created one, this will conflict; merge them by
# hand rather than running both.
resource "aws_cloudwatch_log_resource_policy" "route53" {
  policy_name = "route53-query-logging-${var.subdomain_part}"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowR53LogToCloudwatch"
        Effect = "Allow"
        Principal = {
          Service = "route53.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:log-group:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "query_log" {
  name              = "/aws/route53/${local.subdomain}"
  retention_in_days = var.log_retention_days

  depends_on = [aws_cloudwatch_log_resource_policy.route53]
}

# The child zone this whole port exists to introduce: Cloudflare stays
# authoritative for domain_name, and only this subdomain is delegated to
# Route 53 (see the NS records created in envs/production against the
# Cloudflare provider).
resource "aws_route53_zone" "this" {
  name = local.subdomain

  depends_on = [aws_cloudwatch_log_resource_policy.route53]
}

# Associates the hosted zone with the log group above so DNS queries
# actually get logged. The CDK original built the log group and subscription
# filter but never created this association, so its DNS-trigger path was
# dead — queries were never logged anywhere for the filter to match.
resource "aws_route53_query_log" "this" {
  zone_id                  = aws_route53_zone.this.zone_id
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.query_log.arn

  depends_on = [aws_cloudwatch_log_resource_policy.route53]
}

# Placeholder A record; the watchdog container owns the real value at
# runtime via route53:ChangeResourceRecordSets, so Terraform ignores drift
# on it after creation.
resource "aws_route53_record" "a" {
  zone_id = aws_route53_zone.this.zone_id
  name    = local.subdomain
  type    = "A"
  ttl     = 30
  records = ["192.168.1.1"]

  lifecycle {
    ignore_changes = [records]
  }
}

data "archive_file" "launcher" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/dist/launcher.zip"
}

resource "aws_iam_role" "launcher" {
  name = "${var.subdomain_part}-launcher"

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

resource "aws_iam_role_policy_attachment" "launcher_logs" {
  role       = aws_iam_role.launcher.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "launcher" {
  name              = "/aws/lambda/${var.subdomain_part}-launcher"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "launcher" {
  function_name    = "${var.subdomain_part}-launcher"
  role             = aws_iam_role.launcher.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.13"
  timeout          = 10
  filename         = data.archive_file.launcher.output_path
  source_code_hash = data.archive_file.launcher.output_base64sha256
  # Not setting reserved_concurrent_executions: this account's total Lambda
  # concurrency quota is too low to reserve any for a single function while
  # keeping AWS's mandatory 10-unreserved floor across the account — hit
  # "decreases account's UnreservedConcurrentExecution below its minimum
  # value of [10]" on apply. Revisit if/when the account's quota is raised.

  environment {
    variables = merge(
      {
        REGION  = var.aws_region
        CLUSTER = var.cluster_name
        SERVICE = var.service_name
      },
      var.enable_start_api ? { START_TOKEN = random_password.start_token[0].result } : {}
    )
  }

  depends_on = [aws_cloudwatch_log_group.launcher]
}

# Shared secret for the start API — the Function URL itself has no AWS auth
# (authorization_type = NONE, so it's tappable from a plain browser/phone
# bookmark), so this is what actually gates it. special = false keeps it
# URL-safe with no percent-encoding surprises when pasted into a bookmark.
resource "random_password" "start_token" {
  count = var.enable_start_api ? 1 : 0

  length  = 32
  special = false
}

# Off by default. Lets you start the server from a plain HTTP hit (e.g. a
# phone home-screen bookmark) instead of waiting on the DNS trigger's
# CloudWatch delivery delay. Same launcher Lambda, same idempotent
# check-then-act scale-up — this is just a second way to invoke it.
resource "aws_lambda_function_url" "start" {
  count = var.enable_start_api ? 1 : 0

  function_name      = aws_lambda_function.launcher.function_name
  authorization_type = "NONE"
}

# Companion to the Function URL above — AWS requires an explicit
# resource-based policy statement for public (authorization_type = NONE)
# invocation, separate from the URL resource itself.
resource "aws_lambda_permission" "function_url" {
  count = var.enable_start_api ? 1 : 0

  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.launcher.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# As of October 2025, AWS requires *both* lambda:InvokeFunctionUrl and
# lambda:InvokeFunction on the resource policy for a NONE-auth Function
# URL to actually work — the statement above alone now 403s with
# "AccessDeniedException" despite AuthType being NONE and looking
# otherwise correctly configured. invoked_via_function_url scopes this
# grant to function-URL calls specifically, not just any InvokeFunction.
resource "aws_lambda_permission" "function_url_invoke" {
  count = var.enable_start_api ? 1 : 0

  statement_id             = "AllowPublicFunctionUrlInvokeFunction"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.launcher.function_name
  principal                = "*"
  invoked_via_function_url = true
}

resource "aws_lambda_permission" "cloudwatch" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.launcher.function_name
  principal     = "logs.${data.aws_region.current.region}.amazonaws.com"
  # The trailing :* matters: CloudWatch Logs invokes with a source ARN that
  # includes it (any log stream in the group), but aws_cloudwatch_log_group's
  # own .arn attribute is the bare group ARN without it. Without appending
  # it here, the permission doesn't match what CloudWatch Logs actually
  # presents at invoke time, and PutSubscriptionFilter's own test-invoke
  # fails with "Could not execute the lambda function."
  source_arn = "${aws_cloudwatch_log_group.query_log.arn}:*"
}

# Minecraft Java clients probe an SRV record (_minecraft._tcp.<host>) before
# falling back to a plain A lookup, so this is what actually fires on
# connect. Ported as-is from the CDK original, including its quirk of
# hardcoding subdomain_part into the SRV service prefix — only exactly
# right when subdomain_part is "minecraft" (the default).
resource "aws_cloudwatch_log_subscription_filter" "trigger" {
  name            = "${var.subdomain_part}-launcher-trigger"
  log_group_name  = aws_cloudwatch_log_group.query_log.name
  filter_pattern  = "\"_${var.subdomain_part}._tcp.${local.subdomain}\""
  destination_arn = aws_lambda_function.launcher.arn

  depends_on = [aws_lambda_permission.cloudwatch]
}
