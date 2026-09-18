# aws-mc

An on-demand Minecraft server on AWS Fargate: scales to zero when idle,
started by a DNS lookup, torn down by a watchdog sidecar after everyone
disconnects. Terraform port of
[`minecraft-aws-ondemand`](https://github.com/AndresArcones/minecraft-aws-ondemand)
(a CDK project), fixing its assumption that the domain's parent DNS lives in
Route 53 — here Cloudflare stays authoritative for the domain, and only the
Minecraft subdomain is delegated to Route 53.

## How it works

1. Nothing runs by default — the ECS service sits at `desired_count = 0`.
2. A Minecraft client's connection attempt triggers an SRV DNS lookup
   (`_minecraft._tcp.<subdomain>`), which Route 53 answers (and logs).
3. A CloudWatch Logs subscription filter on that log matches the query and
   invokes a Lambda, which flips the ECS service to `desired_count = 1`.
4. The task starts, mounts the world from EFS, and a watchdog sidecar
   updates the DNS A record to the task's real IP once it's ready.
5. After everyone disconnects for `shutdown_minutes`, the watchdog scales
   the service back to 0.

Step 2→3 goes through CloudWatch Logs delivery, which isn't instant — it
can take anywhere from a few seconds to a couple of minutes. **The first
connection attempt failing is normal, not a bug** — it's what wakes the
server; reconnect after a minute or two. See [Manual start](#manual-start)
if you'd rather skip the wait, or the trigger doesn't fire.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥1.10,
  [`just`](https://github.com/casey/just), AWS CLI
- An AWS account. This project touches VPC/EC2, ECS, EFS, Route 53, Lambda,
  SNS, CloudWatch Logs, S3, IAM, and Resource Groups. For a dedicated IAM
  user rather than granting `AdministratorAccess`, attach:
  `AmazonVPCFullAccess`, `AmazonECS_FullAccess`,
  `AmazonElasticFileSystemFullAccess`, `AmazonRoute53FullAccess`,
  `AWSLambda_FullAccess`, `AmazonSNSFullAccess`, `CloudWatchLogsFullAccess`,
  `AmazonS3FullAccess`, `IAMFullAccess`, `AWSResourceGroupsandTagEditorFullAccess`.
  (`IAMFullAccess` is unavoidably broad — this stack creates and passes IAM
  roles to Lambda/ECS, so the deploy identity is inherently powerful; see
  [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md) for the caveat.)
- A domain already added to **Cloudflare** (nameservers pointed there), with
  nothing currently at `<subdomain_part>.<domain_name>` (default subdomain:
  `minecraft`) — that name needs to be free for the Route 53 delegation.
  You'll need the zone's **Zone ID** (dashboard → Overview → right sidebar)
  and an **API token** scoped to `Zone → DNS → Edit` for that zone (dashboard
  → My Profile → API Tokens → Create Token → "Edit zone DNS" template).

## Credentials

Use a **separate AWS CLI profile** for this project rather than your
default one:

```sh
aws configure --profile aws-mc
```

The [justfile](justfile) exports `AWS_PROFILE=aws-mc` for every recipe
automatically, so `just` commands never touch your default credentials.
Running `aws`/`terraform` directly, outside `just`, needs `--profile aws-mc`
(or `export AWS_PROFILE=aws-mc` for the session) — without it you'll hit
`UnrecognizedClientException`/`InvalidClientTokenId` from whatever your
default profile happens to be.

Secrets (`cloudflare_api_token`) go in `terraform.tfvars` — same role as
`.env` in the CDK original: gitignored, loaded automatically, never
committed. `TF_VAR_cloudflare_api_token` as an env var works too, for CI or
a shared machine.

## Layout

```
bootstrap/            One-time: creates the S3 state bucket. Local state.
envs/production/      The deployable root module. S3 backend, once bootstrapped.
modules/networking/   New VPC (public subnets, no NAT) or reuse an existing one
modules/storage/      EFS + access point for world data
modules/dns-trigger/  Route 53 child zone, query logging, launcher Lambda (us-east-1)
modules/ecs/          Cluster, task def (minecraft + watchdog), Fargate Spot service
modules/notifications/SNS email topic
justfile              Every command below — `just` or `just --list` to see them all
docs/PROJECT_PLAN.md  Full milestone/task breakdown and locked-in decisions
```

## Deploy

```sh
# 1. Create the state bucket (once per AWS account)
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit bucket_name
just bootstrap-init
just bootstrap-apply

# 2. Point envs/production at that bucket
cd ../envs/production
cp backend.hcl.example backend.hcl             # edit bucket/region to match
cp terraform.tfvars.example terraform.tfvars   # edit domain_name, cloudflare_*, etc.
just init

just plan
just apply
```

Confirm the delegation landed:
```sh
just output hosted_zone_name_servers
dig NS minecraft.<your-domain>
```
The four values should match (can take a few minutes to propagate).

## Variables

`envs/production/variables.tf` has the full list with descriptions;
`terraform.tfvars.example` has a ready-to-copy starting point. Highlights:

| Variable | Default | Notes |
|---|---|---|
| `domain_name` | *required* | Cloudflare-managed root domain |
| `cloudflare_zone_id`, `cloudflare_api_token` | *required* | See [Prerequisites](#prerequisites) |
| `subdomain_part` | `minecraft` | Must not already be in use |
| `minecraft_edition` | `java` | or `bedrock` |
| `task_cpu` / `task_memory` | `512` / `1024` | Deliberately tight (half the CDK original) for cost — bump to `1024`/`2048`+ if the server feels sluggish |
| `shutdown_minutes` | `10` | Idle time before scale-to-zero |
| `use_fargate_spot` | `true` | ~1.5c/hr vs ~5c/hr on-demand |
| `sns_email_address` | `""` | Email confirmation is required before you'll receive anything — check spam for it |
| `container_insights` | `false` | Off by default; bills per custom metric |
| `minecraft_image_env_vars` | `{ EULA = "TRUE" }` | Any itzg image setting goes here — see [Customizing the server](#customizing-the-server) |
| `aws_region` | `eu-west-2` | Where the core stack runs. Route 53 query logging always uses us-east-1 regardless — an AWS constraint, not a setting |

Changing any of these is `just plan` / `just apply`; most take effect on
the next server restart, not live (Fargate task definitions are immutable —
a change creates a new revision, which needs a fresh task to pick up).

## Customizing the server

Add keys to `minecraft_image_env_vars` in `terraform.tfvars` — these pass
straight through to the itzg Minecraft image, which maps them onto
`server.properties` (and the server-list icon) at container startup:

```
minecraft_image_env_vars = {
  EULA                = "TRUE"
  OPS                 = "YourExactMinecraftUsername"
  MOTD                = "&6My Server&r\n&aCome build with us!"
  MAX_PLAYERS         = "10"
  ICON                = "https://example.com/icon.png"
  VIEW_DISTANCE       = "10"
  SIMULATION_DISTANCE = "10"
}
```

`OPS` grants operator status on join (case-sensitive, exact username).
`MOTD` supports `&`-prefixed color codes. `ICON` auto-resizes to 64×64.
Many more `server.properties` keys are supported this way — see the
[itzg/docker-minecraft-server docs](https://docker-minecraft-server.readthedocs.io/).

## Operating it

```sh
just status         # desired/running task count
just start          # manual-start fallback, see below
just stop           # force it down now, instead of waiting on shutdown_minutes
just logs-dns        # tail the Route 53 query log (us-east-1) — is a lookup reaching Route 53?
just logs-launcher    # tail the launcher Lambda's log (us-east-1) — is it being invoked?
just sns-status       # confirmed vs PendingConfirmation on the email subscription
just output [name]    # all outputs, or one by name (e.g. server_address)
```

### Manual start

If you don't want to wait on the DNS trigger's CloudWatch delivery delay —
or it isn't firing — skip it entirely:

```sh
just start
```

This flips `desired_count` to 1 directly via the ECS API, the same
out-of-band mechanism the watchdog itself uses (Terraform deliberately
doesn't manage `desired_count` day to day — see `ignore_changes` in
`modules/ecs/main.tf` — so this is always safe to run without fighting a
future `apply`).

## Teardown

```sh
just destroy
```

A couple of things `destroy` won't handle for you:
- **`bootstrap/`'s state bucket** has `prevent_destroy` set and its own
  state — tear it down separately (remove the lifecycle block first) once
  you're sure you don't need the state history.
- **EFS has no automatic backup on delete** (the CDK original's
  `RemovalPolicy.SNAPSHOT` has no direct Terraform equivalent) — snapshot
  the world first (AWS Backup, or copy it off) if it matters to you.

Leaving the stack deployed but idle costs very little either way — the
`desired_count = 0` service, a $0.50/mo Route 53 hosted zone, and
near-zero EFS/Lambda/SNS charges are the only ongoing cost.
