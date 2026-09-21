modules := "modules/networking modules/storage modules/notifications modules/dns-trigger modules/ecs bootstrap envs/production"

# AWS profile every recipe below runs under — keeps this project's
# credentials separate from your default AWS CLI profile/keys. Set up once
# with `aws configure --profile aws-mc`. Override by exporting AWS_PROFILE
# yourself before running just (e.g. in CI, or to use a different profile).
export AWS_PROFILE := env_var_or_default("AWS_PROFILE", "aws-mc")

# Run `just` with no arguments to see this list.
default:
    @just --list

# Format every .tf file in the repo
fmt:
    terraform fmt -recursive

# Check formatting without changing files (same check CI runs)
fmt-check:
    terraform fmt -check -recursive -diff

# init (no backend) + validate every module and both roots — no credentials needed
validate: fmt-check
    #!/usr/bin/env sh
    set -e
    for d in {{modules}}; do
        echo "=== $d ==="
        terraform -chdir="$d" init -backend=false -input=false > /dev/null
        terraform -chdir="$d" validate
    done

# Remove every .terraform/ working directory (safe: leaves .terraform.lock.hcl and state alone)
clean:
    #!/usr/bin/env sh
    find . -type d -name .terraform -prune -exec rm -rf {} +

# --- bootstrap: one-time S3 state bucket setup ---

bootstrap-init:
    terraform -chdir=bootstrap init

bootstrap-plan:
    terraform -chdir=bootstrap plan

bootstrap-apply:
    terraform -chdir=bootstrap apply

# --- envs/production: the deployable stack ---

init:
    terraform -chdir=envs/production init -backend-config=backend.hcl

plan:
    terraform -chdir=envs/production plan

apply:
    terraform -chdir=envs/production apply

destroy:
    terraform -chdir=envs/production destroy

# `just output` for all outputs, or `just output server_address` for one
output name="":
    #!/usr/bin/env sh
    if [ -n "{{name}}" ]; then
        terraform -chdir=envs/production output "{{name}}"
    else
        terraform -chdir=envs/production output
    fi

# Watch the ECS service's desired/running task count — handy while waiting
# for it to scale up after a connect, or back down after shutdown_minutes
status:
    #!/usr/bin/env sh
    set -e
    cluster=$(terraform -chdir=envs/production output -raw ecs_cluster_name | tr -cd 'A-Za-z0-9._/#-')
    service=$(terraform -chdir=envs/production output -raw ecs_service_name | tr -cd 'A-Za-z0-9._/#-')
    aws ecs describe-services --cluster "$cluster" --services "$service" \
        --query "services[0].{desired:desiredCount,running:runningCount,status:status}" --output table

# Manual-start fallback: skip waiting on the DNS trigger (SRV lookup ->
# Route 53 query log -> Lambda) entirely and flip desired_count straight to
# 1. Useful the first time you connect, or if CloudWatch's delivery delay
# (can be a couple of minutes) is more patience than you've got right now.
start:
    #!/usr/bin/env sh
    set -e
    cluster=$(terraform -chdir=envs/production output -raw ecs_cluster_name | tr -cd 'A-Za-z0-9._/#-')
    service=$(terraform -chdir=envs/production output -raw ecs_service_name | tr -cd 'A-Za-z0-9._/#-')
    aws ecs update-service --cluster "$cluster" --service "$service" --desired-count 1 > /dev/null
    echo "Starting. Run 'just status' to watch it come up."

# Print the bookmarkable start URL — a public HTTP hit that starts the
# server, gated by a shared-secret ?token= (not AWS auth), for when you
# want to start it from a phone home-screen bookmark instead of `just
# start` or waiting on the DNS trigger. Only exists when enable_start_api
# = true in terraform.tfvars. Just `just output start_api_url` also works
# (naming a sensitive output reveals it — only the bare, list-everything
# `terraform output` masks sensitive values) but prints it JSON-quoted;
# this uses -raw so it's clean, copy-paste-ready plain text.
start-url:
    #!/usr/bin/env sh
    set -e
    if ! terraform -chdir=envs/production output -json start_api_url >/dev/null 2>&1; then
        echo "No start URL — set enable_start_api = true in terraform.tfvars and apply first."
        exit 1
    fi
    terraform -chdir=envs/production output -raw start_api_url
    echo

# Force the server to stop now, instead of waiting for shutdown_minutes of
# idle time. Terraform doesn't manage desired_count day to day (see
# ignore_changes in modules/ecs/main.tf) — this is the same kind of direct,
# out-of-band control the watchdog itself uses, not a Terraform action.
stop:
    #!/usr/bin/env sh
    set -e
    cluster=$(terraform -chdir=envs/production output -raw ecs_cluster_name | tr -cd 'A-Za-z0-9._/#-')
    service=$(terraform -chdir=envs/production output -raw ecs_service_name | tr -cd 'A-Za-z0-9._/#-')
    aws ecs update-service --cluster "$cluster" --service "$service" --desired-count 0 > /dev/null
    echo "Stopping. Run 'just status' to watch it drain."

# Shell into the running minecraft-server container via ECS Exec (SSM) — no
# network exposure needed, unlike RCON. Requires the server to be running
# (`just start`/`just status`) and the Session Manager plugin installed
# locally: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
# Pass a command to run something specific instead of an interactive shell,
# e.g. `just console "rcon-cli list"` (rcon-cli is bundled in the itzg
# image, so this needs no network RCON access either).
console command="/bin/bash":
    #!/usr/bin/env sh
    set -e
    cluster=$(terraform -chdir=envs/production output -raw ecs_cluster_name | tr -cd 'A-Za-z0-9._/#-')
    service=$(terraform -chdir=envs/production output -raw ecs_service_name | tr -cd 'A-Za-z0-9._/#-')
    task=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" --query "taskArns[0]" --output text)
    if [ -z "$task" ] || [ "$task" = "None" ]; then
        echo "No running task — start the server first with 'just start'."
        exit 1
    fi
    aws ecs execute-command --cluster "$cluster" --task "$task" \
        --container minecraft-server --interactive --command "{{command}}"

# Tail Route 53's DNS query log — shows whether lookups for the server are
# actually reaching Route 53 at all. Always us-east-1, regardless of
# aws_region, since that's where query logging is required to live.
logs-dns:
    #!/usr/bin/env sh
    set -e
    subdomain=$(terraform -chdir=envs/production output -raw server_address | tr -cd 'A-Za-z0-9._/#-')
    aws logs tail "/aws/route53/$subdomain" --region us-east-1 --since 15m --follow

# Tail the launcher Lambda's log — shows whether it's being invoked at all,
# and any errors if it is. Also always us-east-1.
logs-launcher:
    #!/usr/bin/env sh
    set -e
    fn=$(terraform -chdir=envs/production output -raw launcher_function_name | tr -cd 'A-Za-z0-9._/#-')
    aws logs tail "/aws/lambda/$fn" --region us-east-1 --since 15m --follow

# Tail the minecraft-server container's own log (server startup, world
# loading, player join/leave). Only exists when debug = true in
# terraform.tfvars — these log groups aren't created otherwise. A null
# Terraform output isn't stored in state at all, and `output -raw` on a
# name that's absent prints a warning to stdout and exits 0 rather than
# failing — so existence is checked with `output -json` (which does error
# correctly on a missing output) before trusting `-raw` for the value.
logs-minecraft:
    #!/usr/bin/env sh
    set -e
    if ! terraform -chdir=envs/production output -json minecraft_log_group_name >/dev/null 2>&1; then
        echo "No log group — set debug = true in terraform.tfvars and apply first."
        exit 1
    fi
    group=$(terraform -chdir=envs/production output -raw minecraft_log_group_name | tr -cd 'A-Za-z0-9._/#-')
    aws logs tail "$group" --since 15m --follow

# Tail the watchdog sidecar's log (start/shutdown decisions, DNS updates,
# Spot interruption handling). Same debug = true requirement as above.
logs-watchdog:
    #!/usr/bin/env sh
    set -e
    if ! terraform -chdir=envs/production output -json watchdog_log_group_name >/dev/null 2>&1; then
        echo "No log group — set debug = true in terraform.tfvars and apply first."
        exit 1
    fi
    group=$(terraform -chdir=envs/production output -raw watchdog_log_group_name | tr -cd 'A-Za-z0-9._/#-')
    aws logs tail "$group" --since 15m --follow

# Review the SNS topic's subscription statuses — shows whether the email
# subscription is confirmed or pending. If the subscription is pending, check
# your inbox for the confirmation email and click the link.
sns-status:
    #!/usr/bin/env sh
    set -e
    topic=$(terraform -chdir=envs/production output -raw sns_topic_arn | tr -cd 'A-Za-z0-9:._/#-')
    if [ -z "$topic" ]; then
        echo "sns_topic_arn is empty — sns_email_address isn't set in terraform.tfvars"
        exit 1
    fi
    aws sns list-subscriptions-by-topic --topic-arn "$topic" \
        --query "Subscriptions[].{Endpoint:Endpoint,Status:SubscriptionArn}" --output table

# Print the CloudWatch dashboard's console URL. Only exists when
# enable_observability = true in terraform.tfvars.
dashboard-url:
    #!/usr/bin/env sh
    set -e
    if ! terraform -chdir=envs/production output -json dashboard_url >/dev/null 2>&1; then
        echo "No dashboard — set enable_observability = true in terraform.tfvars and apply first."
        exit 1
    fi
    terraform -chdir=envs/production output -raw dashboard_url
    echo
