# aws-mc

Terraform port of [`minecraft-aws-ondemand`](https://github.com/AndresArcones/minecraft-aws-ondemand):
an on-demand Minecraft server on Fargate that scales to zero when idle,
started by a DNS lookup and torn down by a watchdog sidecar. See
[docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md) for the full milestone/task
breakdown this repo is being built against.

Currently at **M1 (parity), code-complete but unapplied**: every Phase 1
module is written and `terraform validate` passes end-to-end, but nothing
has been `apply`'d against real AWS/Cloudflare accounts yet — that's on you,
since it needs real credentials and a real domain. See task 1.9 below for
the functional test to run once you have.

Common commands are in the [justfile](justfile) — `just` (or `just --list`)
shows them all. `just validate` runs the same fmt+validate check CI does,
across every module and both roots, without needing any credentials.

## Layout

```
bootstrap/            One-time: creates the S3 state bucket. Local state.
envs/production/      The deployable root module. S3 backend, once bootstrapped.
modules/networking/   New VPC (public subnets, no NAT) or reuse an existing one
modules/storage/      EFS + access point for world data
modules/dns-trigger/  Route 53 child zone, query logging, launcher Lambda (us-east-1)
modules/ecs/          Cluster, task def (minecraft + watchdog), Fargate Spot service
modules/notifications/SNS email topic
docs/PROJECT_PLAN.md  Full milestone/task breakdown and locked-in decisions
```

## Getting started

```sh
# 1. Create the state bucket (once per AWS account)
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit bucket_name
terraform init
terraform apply

# 2. Point envs/production at that bucket
cd ../envs/production
cp backend.hcl.example backend.hcl             # edit bucket/region to match
cp terraform.tfvars.example terraform.tfvars   # edit domain_name, cloudflare_api_token, etc.
terraform init -backend-config=backend.hcl

terraform plan
terraform apply
```

`terraform.tfvars`, `backend.hcl`, and `*.tfstate` are gitignored — only the
`.example` files are tracked. There's no `.env` here like the CDK original
had; `terraform.tfvars` is the direct equivalent (including for secrets like
`cloudflare_api_token`) — Terraform loads it automatically, and it never
gets committed. If you'd rather not put a secret in a file at all — e.g. on
a shared machine, or setting it in CI — any variable can instead be set as
an env var with a `TF_VAR_` prefix:

```sh
export TF_VAR_cloudflare_api_token="..."       # bash
$env:TF_VAR_cloudflare_api_token = "..."       # PowerShell
```

AWS credentials are separate from all of this — the AWS provider picks them
up the normal way (`aws configure`, `AWS_PROFILE`, etc.), not through
`terraform.tfvars`.

You'll also need, before `apply` works:
- A Cloudflare zone for `domain_name` with `cloudflare_zone_id` and an API
  token scoped to DNS edit on it.
- `subdomain_part` (default `minecraft`) not already in use under that
  domain — Route 53 becomes authoritative for just that subdomain.

## Functional test (task 1.9)

Once applied:
1. Confirm the NS delegation: `dig NS minecraft.<your-domain>` should
   return the four Route 53 name servers from `terraform output
   hosted_zone_name_servers`.
2. Point a Minecraft Java client at `terraform output -raw server_address`.
   The client's automatic SRV lookup on connect is what fires the launcher
   Lambda — a plain `dig A` won't trigger it.
3. Watch `desired_count` on the ECS service go from 0 → 1
   (`aws ecs describe-services --cluster <name> --services <name>`), then
   confirm the world loads once the task is running.
4. If `sns_email_address` was set, confirm the "server ready" email arrives.
5. Disconnect and wait past `shutdown_minutes`; confirm the watchdog scales
   the service back to 0.
