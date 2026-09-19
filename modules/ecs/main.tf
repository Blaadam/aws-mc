locals {
  edition = {
    java = {
      image    = "itzg/minecraft-server"
      port     = 25565
      protocol = "tcp"
    }
    bedrock = {
      image    = "itzg/minecraft-bedrock-server"
      port     = 19132
      protocol = "udp"
    }
  }
  server    = local.edition[var.minecraft_edition]
  rcon_port = 25575

  # Guarded by var.debug itself, not just where these get used below —
  # aws_cloudwatch_log_group.minecraft/watchdog have count = 0 when
  # !var.debug, and indexing [0] into a zero-count resource is a hard error
  # even in a branch that's never used downstream, unless the conditional
  # expression itself is what decides whether to evaluate that index.
  mc_log_config = var.debug ? {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.minecraft[0].name
      "awslogs-region"        = data.aws_region.current.region
      "awslogs-stream-prefix" = "minecraft-server"
    }
  } : null

  watchdog_log_config = var.debug ? {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.watchdog[0].name
      "awslogs-region"        = data.aws_region.current.region
      "awslogs-stream-prefix" = "minecraft-ecsfargate-watchdog"
    }
  } : null

  service_control_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAllOnServiceAndTask"
        Effect = "Allow"
        Action = "ecs:*"
        Resource = [
          aws_ecs_service.this.id,
          "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task/${var.cluster_name}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeNetworkInterfaces"
        Resource = "*"
      },
    ]
  })
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- Cluster -----------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.exec.name
      }
    }
  }
}

# ECS Exec session transcripts — an audit trail for admin shell access, not
# a debug log, so this always exists regardless of var.debug.
resource "aws_cloudwatch_log_group" "exec" {
  name              = "/ecs/${var.cluster_name}/exec"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# --- Networking ----------------------------------------------------------

# EFS ingress is added by the caller (envs/production) to avoid a cycle
# between this module and the storage module.
resource "aws_security_group" "service" {
  name        = "${var.cluster_name}-service"
  description = "Minecraft on-demand service"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.cluster_name}-service" }
}

resource "aws_vpc_security_group_ingress_rule" "game" {
  security_group_id = aws_security_group.service.id
  description       = "Minecraft ${var.minecraft_edition} game port"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = local.server.port
  to_port           = local.server.port
  ip_protocol       = local.server.protocol
}

# Off by default (var.rcon_allowed_cidrs = []) — nothing in this stack needs
# RCON reachable from outside the task; the watchdog's readiness check talks
# to it over localhost. One rule per CIDR since this resource type takes a
# single cidr_ipv4, not a list.
resource "aws_vpc_security_group_ingress_rule" "rcon" {
  for_each = toset(var.rcon_allowed_cidrs)

  security_group_id = aws_security_group.service.id
  description       = "RCON admin access (manually opted in via rcon_allowed_cidrs)"
  cidr_ipv4         = each.value
  from_port         = local.rcon_port
  to_port           = local.rcon_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.service.id
  description       = "Unrestricted egress: image pulls, EFS, AWS API calls"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- IAM -------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name = "${var.cluster_name}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "${var.cluster_name}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "efs_rw" {
  name = "efs-rw"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadWriteOnEFS"
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeFileSystems",
        ]
        Resource = var.efs_file_system_arn
        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = var.efs_access_point_arn
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "route53_edit" {
  name = "route53-edit"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEditRecordSets"
        Effect = "Allow"
        Action = [
          "route53:GetHostedZone",
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.hosted_zone_id}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The SSM Session Manager channel ECS Exec runs over — these actions
        # don't support resource-level scoping (AWS constraint, same as
        # ec2:DescribeNetworkInterfaces above).
        Sid    = "AllowExecSSMChannel"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowExecSessionLogging"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.exec.arn}:*"
      },
      {
        # logs:DescribeLogGroups doesn't support resource-level scoping
        # (AWS constraint) — must be "*".
        Sid      = "AllowExecLogGroupDiscovery"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "sns_publish" {
  count = var.sns_topic_configured ? 1 : 0

  name = "sns-publish"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = var.sns_topic_arn
      }
    ]
  })
}

# The watchdog scales its own service via the task role; the launcher Lambda
# needs the same permission to scale it back up from zero.
resource "aws_iam_role_policy" "service_control_task" {
  name   = "service-control"
  role   = aws_iam_role.task.id
  policy = local.service_control_policy
}

resource "aws_iam_role_policy" "service_control_launcher" {
  name   = "service-control"
  role   = var.launcher_role_name
  policy = local.service_control_policy
}

# --- Logs (only when debug = true) ------------------------------------

resource "aws_cloudwatch_log_group" "minecraft" {
  count = var.debug ? 1 : 0

  name              = "/ecs/${var.cluster_name}/minecraft-server"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "watchdog" {
  count = var.debug ? 1 : 0

  name              = "/ecs/${var.cluster_name}/minecraft-ecsfargate-watchdog"
  retention_in_days = var.log_retention_days
}

# --- Task + service ----------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.service_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "data"

    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    merge(
      {
        name      = "minecraft-server"
        image     = local.server.image
        essential = false
        portMappings = [
          {
            containerPort = local.server.port
            hostPort      = local.server.port
            protocol      = local.server.protocol
          }
        ]
        environment = [
          for k, v in var.minecraft_image_env_vars : { name = k, value = v }
        ]
        mountPoints = [
          {
            sourceVolume  = "data"
            containerPath = "/data"
            readOnly      = false
          }
        ]
        # AWS-recommended for ECS Exec: reaps processes spawned by exec
        # sessions (e.g. rcon-cli) instead of leaving zombies behind.
        linuxParameters = {
          initProcessEnabled = true
        }
      },
      var.debug ? { logConfiguration = local.mc_log_config } : {}
    ),
    merge(
      {
        name      = "minecraft-ecsfargate-watchdog"
        image     = "doctorray/minecraft-ecsfargate-watchdog"
        essential = true
        environment = [
          { name = "CLUSTER", value = var.cluster_name },
          { name = "SERVICE", value = var.service_name },
          { name = "DNSZONE", value = var.hosted_zone_id },
          { name = "SERVERNAME", value = var.subdomain },
          { name = "SNSTOPIC", value = var.sns_topic_arn },
          { name = "STARTUPMIN", value = tostring(var.startup_minutes) },
          { name = "SHUTDOWNMIN", value = tostring(var.shutdown_minutes) },
        ]
      },
      var.debug ? { logConfiguration = local.watchdog_log_config } : {}
    ),
  ])
}

resource "aws_ecs_service" "this" {
  name                   = var.service_name
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = 0
  platform_version       = "LATEST"
  enable_execute_command = true

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = true
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this]

  lifecycle {
    # The watchdog and launcher Lambda flip this at runtime; Terraform must
    # not fight them by resetting it to 0 on every apply.
    ignore_changes = [desired_count]
  }
}
