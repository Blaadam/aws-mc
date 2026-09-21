# aws-mc

This is an on-demand minecraft server, inspired by [minecraft-aws-ondemand](https://github.com/AndresArcones/minecraft-aws-ondemand). This is project intends to help with cost-savings, so you aren't paying for a server that isn't actively being used. There are two ways to wake the server - through a DNS Query, or through an optional lambda API url. After 10 minutes of no user activity, the server will automatically shutdown.

Just to let you know, this is the first project I've worked on where I've had to setup terraform. I have a Solutions Architect Associate certification for AWS so I have some prior experience, but if there is anything you can find - either with terraform or AWS to help simplify/reduce cost, then please make a pull request or issue!

By default, the lowest-cost resources are applied (0.5vcpu and 1024mb ram) - however, to meet minecraft's requirements I suggest upping this to 1vcpu and 2024mb ram.

I built this to work with my cloudflare domain - some configuration may be needed to deploy on Route 53 fully (see [Deploy](#deploy)).

For the DNS querying to be picked up, the trigger logic sits in us-east-1 - but you are able to configure which region you want to use for the server.

## Architecture

![Architecture diagram: a Minecraft client's SRV lookup reaches a Route 53 Hosted Zone in us-east-1, whose query logs flow through CloudWatch to a launcher Lambda that scales the chosen-region ECS Fargate service from 0 to 1; the task mounts world data from EFS and runs a watchdog sidecar that updates the A record once healthy, then scales the service back to 0 after idle time; start/stop events publish to SNS for email and to a Lambda that relays to Discord; Cloudflare optionally handles the one-time NS delegation for the subdomain.](docs/aws-mc.png)

## How it works

By default, nothing runs at all, this is the behaviour that keeps the ongoing cost minimal — the ECS service is held at `desired_count = 0`. When a player tries to connect, the Minecraft client performs an SRV DNS lookup against `_minecraft._tcp.<subdomain>`, which Route 53 answers and simultaneously logs. A CloudWatch Logs subscription filter on that log group matches the query and invokes the launcher Lambda, which flips the ECS service to `desired_count = 1`.

The task then starts, mounts the world from the EFS access point, and a watchdog sidecar updates the Route 53 A record to the real task IP once the container is ready. After every player has disconnected for `shutdown_minutes`, the watchdog scales the service back down to 0.

The path from step 2 to step 3 travels through CloudWatch Logs delivery, which is not instantaneous — it can take anywhere from a few seconds to a couple of minutes. **The first connection attempt failing is normal, not a bug**, because that DNS lookup is what wakes the server in the first place, you should reconnect after a minute or two. If you would rather skip the wait, or if the trigger is not firing for some reason, see [Manual start](#manual-start).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥1.10, [`just`](https://github.com/casey/just), and the AWS CLI. These are needed because the deployment is driven entirely by Terraform, and the [justfile](justfile) wraps the common commands so they are consistent.
- The [Session Manager plugin for the AWS CLI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) — this is only required for `just console`, because ECS Exec relies on it.
- An AWS account. This project touches VPC/EC2, ECS, EFS, Route 53, Lambda, SNS, CloudWatch Logs, S3, IAM, and Resource Groups, so the deploy identity needs a fairly broad set of permissions. If you prefer a dedicated IAM user rather than granting `AdministratorAccess`, you can attach: `AmazonVPCFullAccess`, `AmazonECS_FullAccess`, `AmazonElasticFileSystemFullAccess`, `AmazonRoute53FullAccess`, `AWSLambda_FullAccess`, `AmazonSNSFullAccess`, `CloudWatchLogsFullAccess`, `AmazonS3FullAccess`, `IAMFullAccess`, and `AWSResourceGroupsandTagEditorFullAccess`. (`IAMFullAccess` is unavoidably broad — this stack creates and passes IAM roles to Lambda and ECS, so the deploy identity is inherently powerful; see [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md) for the caveat.)
- A domain, with nothing currently at `<subdomain_part>.<domain_name>` (the default subdomain is `minecraft`) — that name needs to be free because Route 53 is going to delegate it as a child Hosted Zone. If it is on **Cloudflare** and you want delegation automated (`manage_cloudflare_dns = true`), you will also need the zone's **Zone ID** (dashboard → Overview → right sidebar) and an **API token** scoped to `Zone → DNS → Edit` for that zone (dashboard → My Profile → API Tokens → Create Token → "Edit zone DNS" template). Anywhere else (Route 53 itself, Namecheap, GoDaddy, etc.), leave `manage_cloudflare_dns` at its default (`false`) and delegate manually — see [Deploy](#deploy).

## Credentials

I recommend using a **separate AWS CLI profile** for this project rather than touching your default credentials:

```sh
aws configure --profile aws-mc
```

The [justfile](justfile) exports `AWS_PROFILE=aws-mc` for every recipe, so `just` commands will never touch your default profile. If you run `aws` or `terraform` directly, outside `just`, you will need `--profile aws-mc` (or `export AWS_PROFILE=aws-mc` for the session) — without it you will hit `UnrecognizedClientException` or `InvalidClientTokenId` from whatever your default profile happens to be.

Secrets, such as `cloudflare_api_token`, belong in `terraform.tfvars`. That file plays the same role as `.env` in the CDK original: it is gitignored, it is loaded automatically, and it should never be committed. You can also pass `TF_VAR_cloudflare_api_token` as an environment variable, which is useful for CI or a shared machine.

## Layout

```
bootstrap/            One-time: creates the S3 state bucket. Local state is fine here.
envs/production/      The deployable root module. Uses an S3 backend once bootstrapped.
modules/networking/   New VPC (public subnets, no NAT) or reuse an existing one.
modules/storage/      EFS and an access point for the world data.
modules/dns-trigger/  Route 53 child zone, query logging, and the launcher Lambda (us-east-1).
modules/ecs/          Cluster, task definition (Minecraft + watchdog), and Fargate Spot service.
modules/notifications/SNS email topic and Discord relay Lambda.
justfile              Every command below is in here — run `just` or `just --list` to see them all.
docs/PROJECT_PLAN.md  Full milestone/task breakdown and locked-in decisions.
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

Next, you need to delegate the child zone. **If `manage_cloudflare_dns = true`**, Terraform has already done this, so you can skip straight to confirming it landed. **Otherwise**, do this yourself once, wherever `domain_name`'s DNS actually lives (including Route 53 itself, if that is already your authoritative DNS provider — just add the same NS record set to your existing Hosted Zone):

```sh
just output hosted_zone_name_servers
```

Create an NS record for `<subdomain_part>.<domain_name>` pointing at those four values.

Confirm the delegation landed (either way):

```sh
dig NS minecraft.<your-domain>
```

The four values should match, although it can take a few minutes to propagate.

## Variables

`envs/production/variables.tf` has the full list with descriptions, and `terraform.tfvars.example` has a ready-to-copy starting point. The highlights below explain the variables that matter most:

| Variable                                     | Default             | Notes                                                                                                                                                                                                                                                                                            |
| -------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `domain_name`                                | _required_          | Root domain, hosted anywhere — see [Prerequisites](#prerequisites).                                                                                                                                                                                                                              |
| `manage_cloudflare_dns`                      | `false`             | Automates NS delegation in Cloudflare. Leave `false` for any other DNS host and delegate manually.                                                                                                                                                                                               |
| `cloudflare_zone_id`, `cloudflare_api_token` | `""`                | Required only when `manage_cloudflare_dns = true` — see [Prerequisites](#prerequisites).                                                                                                                                                                                                         |
| `subdomain_part`                             | `minecraft`         | Must not already be in use.                                                                                                                                                                                                                                                                      |
| `minecraft_edition`                          | `java`              | or `bedrock`.                                                                                                                                                                                                                                                                                    |
| `task_cpu` / `task_memory`                   | `512` / `1024`      | Deliberately tight (half the CDK original) for cost — bump to `1024`/`2048`+ if the server feels sluggish.                                                                                                                                                                                       |
| `shutdown_minutes`                           | `10`                | Idle time before scale-to-zero.                                                                                                                                                                                                                                                                  |
| `use_fargate_spot`                           | `true`              | ~1.5c/hr vs ~5c/hr on-demand.                                                                                                                                                                                                                                                                    |
| `sns_email_address`                          | `""`                | Email confirmation is required before you'll receive anything — check spam for it.                                                                                                                                                                                                               |
| `discord_webhook_url`                        | `""`                | Relays the same start/stop notification to Discord — it is independent of `sns_email_address`, so it works with or without email too.                                                                                                                                                            |
| `discord_message`                            | `""`                | Optional text prepended above the notification in Discord (e.g. `@everyone`). No effect when `discord_webhook_url` is unset.                                                                                                                                                                     |
| `container_insights`                         | `false`             | Off by default, because it bills per custom metric.                                                                                                                                                                                                                                              |
| `minecraft_image_env_vars`                   | `{ EULA = "TRUE" }` | Any itzg image setting goes here — see [Customizing the server](#customizing-the-server).                                                                                                                                                                                                        |
| `aws_region`                                 | `eu-west-2`         | Where the core stack runs. Route 53 query logging always uses us-east-1 regardless — this is an AWS constraint, not a setting.                                                                                                                                                                   |
| `rcon_allowed_cidrs`                         | `[]`                | CIDR blocks allowed to reach RCON (25575/tcp) — closed by default, because nothing in this stack needs it open. Set to your own IP (e.g. `["203.0.113.4/32"]`) if you want to run admin commands yourself via `mcrcon`. Never `0.0.0.0/0` — RCON auth is a plaintext password.                   |
| `enable_start_api`                           | `false`             | Public HTTP URL that starts the server — see [Manual start](#manual-start). No AWS auth on the URL, it is gated by a generated `?token=` instead. Start-only. When set alongside `discord_webhook_url`, the Discord shutdown notification gets a "Restart server" button linking straight to it. |

Changing any of these is `just plan` / `just apply`; most take effect on the next server restart rather than live, because Fargate task definitions are immutable — a change creates a new revision, and a fresh task is needed to pick it up.

## Customizing the server

Add keys to `minecraft_image_env_vars` in `terraform.tfvars` — these pass straight through to the itzg Minecraft image, which maps them onto `server.properties` (and the server-list icon) at container startup:

```tf
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

`OPS` grants operator status on join (case-sensitive, exact username). `MOTD` supports `&`-prefixed colour codes. `ICON` auto-resizes to 64×64. Many more `server.properties` keys are supported this way — see the [itzg/docker-minecraft-server docs](https://docker-minecraft-server.readthedocs.io/).

## Operating it

```sh
just status          # desired/running task count
just start           # manual-start fallback, see below
just start-url       # print the bookmarkable HTTP start URL — needs enable_start_api = true
just stop            # force it down now, instead of waiting on shutdown_minutes
just console         # shell into the running server via ECS Exec — no network access needed
just logs-dns        # tail the Route 53 query log (us-east-1) — is a lookup reaching Route 53?
just logs-launcher   # tail the launcher Lambda's log (us-east-1) — is it being invoked?
just logs-minecraft  # tail the server's own log — needs debug = true in terraform.tfvars
just logs-watchdog   # tail the watchdog's log — start/shutdown decisions, DNS updates
just sns-status      # confirmed vs PendingConfirmation on the email subscription
just output [name]   # all outputs, or one by name (e.g. server_address)
```

### Manual start

If you would rather not wait for the DNS trigger's CloudWatch delivery delay — or if it is not firing — you can skip it entirely:

```sh
just start
```

This flips `desired_count` to 1 directly via the ECS API, the same out-of-band mechanism the watchdog itself uses. Terraform deliberately does not manage `desired_count` day to day — see `ignore_changes` in `modules/ecs/main.tf` — so this is always safe to run without fighting a future `apply`.

`just start` needs your AWS CLI credentials, however. For starting the server from somewhere those are not available (for example, a phone), set `enable_start_api = true` and use the bookmarkable HTTP URL instead:

```sh
just start-url
```

That prints a URL with a generated secret baked in (`?token=...`) — the Function URL itself has no AWS auth, so the token is the only thing gating it. You can bookmark it, tap it, and the server will start in the same way that `just start` does. There is no equivalent stop URL yet — you still use `just stop`, or rely on `shutdown_minutes` of idle time — this is deliberately start-only for now.

### Admin access

RCON (25575/tcp) is closed to the internet by default — see [`rcon_allowed_cidrs`](#variables) if you want it open to a specific IP. For most admin needs, `just console` is the better default: it shells into the running container via ECS Exec (IAM-authenticated over SSM, with no network exposure at all), where `rcon-cli` is already available:

```sh
just console "rcon-cli list"   # one-shot command
just console                   # interactive shell (default)
```

## Teardown

```sh
just destroy
```

A couple of things `destroy` will not handle for you:

- **`bootstrap/`'s state bucket** has `prevent_destroy` set and its own local state — tear it down separately (remove the lifecycle block first) once you are sure you do not need the state history anymore.
- **EFS has no automatic backup on delete**, because the CDK original's `RemovalPolicy.SNAPSHOT` has no direct Terraform equivalent — snapshot the world first (AWS Backup, or copy it off) if the data matters to you.

Leaving the stack deployed but idle costs very little either way — the `desired_count = 0` service, a $0.50/mo Route 53 Hosted Zone, and near-zero EFS/Lambda/SNS charges are the only ongoing costs.
