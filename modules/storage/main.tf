# Ingress is added by the caller (envs/production), which also owns the ECS
# service's security group — avoids a networking <-> ecs module cycle.
resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs"
  description = "Minecraft world data EFS"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.project_name}-efs" }
}

# The CDK original used RemovalPolicy.SNAPSHOT (best-effort backup-on-delete
# via a CloudFormation custom resource). Terraform has no equivalent; back
# this up with AWS Backup or a manual snapshot before destroying.
resource "aws_efs_file_system" "this" {
  encrypted = true

  # The world sits untouched almost all the time (server's scaled to zero
  # between sessions) — move it to cheaper Infrequent Access storage after
  # a month unused, and pull it back to Standard automatically on next read
  # (server start). Pure cost saving, no availability tradeoff.
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = { Name = "${var.project_name}-data" }
}

resource "aws_efs_access_point" "this" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/minecraft"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = { Name = "${var.project_name}-access-point" }
}

# count instead of for_each: on a brand-new VPC the subnet IDs are unknown
# until apply, and for_each needs its keys known up front. The number of
# subnets is known at plan time even though their IDs aren't (it comes from
# aws_subnet.public's count in the networking module, resolved from the
# aws_availability_zones data source), so count = length(...) works.
resource "aws_efs_mount_target" "this" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}
