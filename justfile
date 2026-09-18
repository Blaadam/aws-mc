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
