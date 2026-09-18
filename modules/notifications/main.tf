resource "aws_sns_topic" "this" {
  count = var.sns_email_address != "" ? 1 : 0
  name  = "${var.project_name}-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.sns_email_address != "" ? 1 : 0

  topic_arn = aws_sns_topic.this[0].arn
  protocol  = "email"
  endpoint  = var.sns_email_address
}
