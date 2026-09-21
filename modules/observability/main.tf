locals {
  # Empty when sns_topic_arn isn't set — an alarm with no actions still
  # exists and is visible in the console, it just doesn't notify anywhere.
  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
}

resource "aws_cloudwatch_metric_alarm" "launcher_errors" {
  alarm_name         = "${var.project_name}-launcher-errors"
  alarm_description  = "Launcher Lambda (DNS trigger + start API) threw an error."
  namespace          = "AWS/Lambda"
  metric_name        = "Errors"
  dimensions         = { FunctionName = var.launcher_function_name }
  statistic          = "Sum"
  period             = 300
  evaluation_periods = 1

  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "discord_errors" {
  count = var.discord_function_name != "" ? 1 : 0

  alarm_name         = "${var.project_name}-discord-notify-errors"
  alarm_description  = "Discord-notify Lambda threw an error relaying a start/stop notification."
  namespace          = "AWS/Lambda"
  metric_name        = "Errors"
  dimensions         = { FunctionName = var.discord_function_name }
  statistic          = "Sum"
  period             = 300
  evaluation_periods = 1

  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# Cost safety net, not a gameplay alarm. CPUUtilization is only published
# while the service actually has a running task, so continuous data for N
# straight hourly periods means the task has been up that whole time
# without scaling to zero — either a genuinely long session, or the
# watchdog failed to shut it down (Spot interruption mid-shutdown, a
# crash, a bug). Threshold is deliberately -1, since CPU% is never
# negative: this fires purely on data being *present* for N consecutive
# hours, regardless of actual utilization level — a real "still up"
# check, not a load-based one.
resource "aws_cloudwatch_metric_alarm" "long_running" {
  alarm_name        = "${var.project_name}-long-running"
  alarm_description = "Server has been running continuously for ${var.long_running_alarm_hours}h+ without scaling to zero — worth checking it hasn't gotten stuck up."
  namespace         = "AWS/ECS"
  metric_name       = "CPUUtilization"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = var.long_running_alarm_hours
  datapoints_to_alarm = var.long_running_alarm_hours

  threshold           = -1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.project_name

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 12
          height = 6
          properties = {
            title  = "ECS task CPU / memory"
            region = var.aws_region
            view   = "timeSeries"
            metrics = [
              ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Maximum", label = "CPU %" }],
              ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { stat = "Maximum", label = "Memory %" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 0
          width  = 12
          height = 6
          properties = {
            title  = "Launcher Lambda (DNS trigger + start API)"
            region = var.aws_region
            view   = "timeSeries"
            metrics = [
              ["AWS/Lambda", "Invocations", "FunctionName", var.launcher_function_name, { stat = "Sum", label = "Invocations" }],
              ["AWS/Lambda", "Errors", "FunctionName", var.launcher_function_name, { stat = "Sum", label = "Errors" }],
            ]
          }
        },
      ],
      # Only when discord_webhook_url is actually set — otherwise the
      # function (and this metric data) doesn't exist.
      var.discord_function_name != "" ? [
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 12
          height = 6
          properties = {
            title  = "Discord-notify Lambda"
            region = var.aws_region
            view   = "timeSeries"
            metrics = [
              ["AWS/Lambda", "Invocations", "FunctionName", var.discord_function_name, { stat = "Sum", label = "Invocations" }],
              ["AWS/Lambda", "Errors", "FunctionName", var.discord_function_name, { stat = "Sum", label = "Errors" }],
            ]
          }
        },
      ] : []
    )
  })
}
