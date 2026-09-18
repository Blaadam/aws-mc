# Project plan: CDK → Terraform port

Rebuild [`minecraft-aws-ondemand`](https://github.com/AndresArcones/minecraft-aws-ondemand)
(CDK) as a Terraform project that keeps the on-demand behaviour and cost
model of the original, while fixing the Cloudflare-parent DNS assumption and
tightening IAM, secrets, and observability.

**In scope:** full infra port, Cloudflare NS delegation, least-privilege IAM,
CI checks, world-data migration.
**Out of scope for the core:** the NLB redesign and any change to the itzg
containers themselves (reused as-is).

## Milestones (the gates)

| Gate | Meaning | Acceptance |
|---|---|---|
| **M0 — Scaffolded** | Repo, backend, providers, CI skeleton | `terraform plan` runs clean; CI passes `fmt`/`validate` |
| **M1 — Parity** | Feature-complete port | Cold-start from a DNS lookup, world persists on EFS, scales to zero after `SHUTDOWN_MINUTES`, a notification fires |
| **M2 — Hardened** | Production-ready | Least-priv IAM, Twilio creds in Secrets Manager, images pinned by digest, CI security scan green, dashboard + alarms live |
| **M3 — Improved (optional)** | Better trigger | Cloudflare Worker start endpoint live; query-log trigger retired |

## Task breakdown

**Phase 0 — Scaffolding (~4h)**

| ID | Task | Depends on | Est |
|---|---|---|---|
| 0.1 | Init repo, choose Terraform/OpenTofu, pin versions | — | 0.5h |
| 0.2 | S3 backend with native lockfile (`use_lockfile`) | 0.1 | 1h |
| 0.3 | AWS provider + `us-east-1` alias; Cloudflare provider | 0.1 | 1h |
| 0.4 | Map every `.env` key to `variables.tf` (this is the parity checklist) | 0.1 | 1h |
| 0.5 | CI skeleton: `fmt` + `validate` on PR | 0.1 | 0.5h |

**Phase 1 — Functional port (~12–16h, one weekend)**

| ID | Task | Status |
|---|---|---|
| 1.1 | `networking` module (new VPC or data-source existing) | ✅ done |
| 1.2 | `storage` module: EFS + access point | ✅ done |
| 1.3 | `ecs` module: cluster, task def (minecraft + watchdog), Fargate **Spot** service `desired_count=0` | ✅ done |
| 1.4 | `dns-trigger`: Route 53 child zone, query logging, subscription filter, launcher Lambda | ✅ done |
| 1.5 | Cloudflare NS delegation (output child NS → `cloudflare_record`, provider v4 resource name) | ✅ done |
| 1.6 | A record with `ignore_changes=[records]`; watchdog owns runtime value | ✅ done |
| 1.7 | `notifications`: SNS email path | ✅ done |
| 1.8 | Wire modules in `envs/production` | ✅ done (validated; not yet applied — needs your real AWS/Cloudflare credentials) |
| 1.9 | **Functional test**: connect → start → world loads → idle → scale to 0 | ⬜ pending — needs a real `apply` |

**Phase 2 — Harden (~16–24h)**

| ID | Task | Depends on | Est |
|---|---|---|---|
| 2.1 | Split IAM: least-priv launcher role + scoped watchdog task role | 1.3, 1.4 | 3h |
| ~~2.2~~ | ~~Twilio creds → Secrets Manager; wire Twilio SMS Lambda~~ — dropped, see Decisions | — | — |
| 2.3 | Upgrade launcher Lambda to Python 3.13; make idempotent | 1.4 | 1.5h |
| 2.4 | Pin both containers by digest; log retention | 1.3 | 1h |
| 2.5 | `observability`: CloudWatch dashboard + start/idle/error alarms | 1.8 | 3h |
| 2.6 | CI: add `tflint` + tfsec/Checkov + `plan` on PR | 0.5 | 2h |
| 2.7 | README: variables, deploy, manual-start fallback, teardown | all | 2h |
| 2.8 | Re-run functional test on hardened stack | 2.1–2.6 | 1.5h |

**Phase 3 — Improved trigger (optional, ~6–8h)**

| ID | Task | Depends on | Est |
|---|---|---|---|
| 3.1 | Lambda Function URL → `desired_count=1` | 2.1 | 2h |
| 3.2 | Cloudflare Worker behind Access as start endpoint | 3.1 | 3h |
| 3.3 | Retire query-log trigger; keep watchdog for scale-down | 3.2 | 1h |

**Migration (do once, before cutover): ~3h.** Snapshot the old stack's EFS,
restore into the new EFS, verify the world loads, cut DNS over, then tear
down the CDK stacks. Run the new stack in parallel under a different
zone/name first — don't destroy the old one until M1 passes on real data.

## Rough schedule

Core (Phases 0–2) is ~35–45h. At a couple of weekday evenings plus one
weekend session per week, that's about **4 weeks**; a focused fortnight if
you push.

- **Wk 1:** Phase 0 + start Phase 1 — reach a first `apply`.
- **Wk 2:** Finish Phase 1, hit **M1** on a throwaway zone.
- **Wk 3:** Phase 2 hardening.
- **Wk 4:** CI + docs + migration, hit **M2**, cut over.
- **Later:** Phase 3 when the DNS trigger annoys you enough.

## Risks

| Risk | Mitigation |
|---|---|
| DNS query-log trigger fires late or on stray lookups | Client-side retry + documented manual start; Phase 3 removes it |
| Spot interruption mid-game | Verify watchdog SIGTERM handling explicitly in 1.9, don't assume it |
| World-data loss on migration | Snapshot + verify restore before touching the old stack |
| Forgetting the `us-east-1` coupling for query logging | Provider alias in 0.3, referenced in 1.4 |
| Secrets leaking via state/tfvars | Secrets Manager (2.2), encrypted S3 state, gitignore tfvars |
| Cost creep from private subnets | Stay public-subnet in Phase 1; NAT/endpoints only if you go private |

## Decisions locked in during scaffolding (M0)

- **IaC tool:** Terraform (not OpenTofu).
- **Networking:** new dedicated VPC per Phase 1, public subnets only, no NAT
  gateways — same cost as reusing a default VPC (both ~$0), but avoids
  coupling this project to whatever else lives in the account's default VPC.
- **Region:** core stack defaults to `eu-west-2` (UK-based), exposed as
  `var.aws_region` so it's not hardcoded. Route 53 query logging still
  requires `us-east-1` regardless — that's a fixed AWS constraint, handled via
  a provider alias, not a variable.
- **State backend:** S3 with native `use_lockfile` locking (Terraform
  ≥1.10), no DynamoDB table. Bucket is created once via `bootstrap/`.
- **Notifications:** Twilio SMS dropped for now — SNS email
  (`sns_email_address`) is the only notification path. The
  `TWILIO_PHONE_FROM`/`TWILIO_PHONE_TO`/`TWILIO_ACCOUNT_ID`/`TWILIO_AUTH_CODE`
  variables from the CDK original are not carried over; task 2.2 (Secrets
  Manager + SMS Lambda) is dropped accordingly. Easy to re-add later if
  wanted — the watchdog container already accepts `TWILIOFROM`/`TWILIOTO`/
  `TWILIOAID`/`TWILIOAUTH` env vars, so it's just re-adding the variables and
  wiring them into the `ecs` module's watchdog container definition.

## Decisions locked in during Phase 1

- **Missing query-logging association (bug fix, not scope creep):** the CDK
  original builds the CloudWatch log group and subscription filter but never
  associates that log group with the hosted zone as a query-logging
  destination (no `CfnQueryLoggingConfig`) — so DNS queries were never
  logged anywhere, and the whole "cold-start from a DNS lookup" mechanism
  was dead code upstream. Added `aws_route53_query_log` in `dns-trigger` to
  actually wire it up, since it's what task 1.4 ("query logging") already
  called for.
- **SSM parameter cross-region relay dropped:** the CDK original stores the
  hosted zone ID and launcher Lambda role ARN in SSM via a custom
  `SSMParameterReader` resource, purely to work around CloudFormation not
  supporting cross-region cross-stack references. Terraform doesn't have
  that limitation — module outputs work across providers/regions in one
  state — so this is a plain `module.dns_trigger.hosted_zone_id` reference
  in `envs/production/main.tf` and the custom resource isn't ported at all.
- **`dns-trigger` module runs entirely in us-east-1**, including the hosted
  zone itself, via `providers = { aws = aws.use1 }` at the call site —
  mirrors the CDK original's `DomainStack` region, keeps the "why us-east-1"
  reasoning in one place.
- **storage ↔ ecs module cycle broken at the root:** the EFS security group
  (in `storage`) and the ECS service security group (in `ecs`) each own no
  ingress rules referencing the other module — the ingress rule connecting
  them (`aws_vpc_security_group_ingress_rule.efs_from_ecs`) lives in
  `envs/production/main.tf` instead, since neither module can depend on the
  other's output without creating a real Terraform module cycle.
- **`desired_count` drift is ignored** (`lifecycle.ignore_changes` on
  `aws_ecs_service.this`) since the watchdog and launcher Lambda flip it at
  runtime — an unrelated `terraform apply` must not reset a running server
  back to 0.
- **Launcher Lambda runtime is Python 3.12**, not the CDK original's 3.8
  (no longer creatable on Lambda) and not yet 3.13 — that bump, plus making
  the handler idempotent, is what task 2.3 is for.
- **RCON (25575/tcp) is open to `0.0.0.0/0`** on the service security group,
  ported as-is from the CDK original. Worth tightening in task 2.1
  (least-priv IAM/network hardening) — nothing currently restricts it.
- **AWS provider pinned to `~> 5.0`, not v6:** v6 renamed several
  attributes (e.g. `aws_region.name` → `aws_region.region`) and likely has
  other breaking changes across the resources this project uses (ECS, IAM,
  Route 53, Lambda, EFS). Staying on 5.x for now; revisit as a deliberate
  upgrade later, not an incidental one.
- **Defaults tuned for lowest cost, not reliability** — the architecture
  already gets the big win (Spot + scale-to-zero); these are the remaining
  levers, all overridable in `terraform.tfvars`:
  - `task_cpu`/`task_memory` default to 512/1024 (0.5 vCPU, 1GB) — half the
    CDK original's 1024/2048. Below Mojang's official 2GB+ recommendation;
    workable for a small vanilla world, tight for modpacks or several
    concurrent players.
  - `shutdown_minutes` defaults to 10, not the original's 20 — every minute
    here is billed Fargate time with nobody connected.
  - `container_insights` (new variable, no CDK equivalent) defaults to
    `false` — Container Insights bills per custom CloudWatch metric, which
    isn't worth it for a server that's mostly scaled to zero.
  - EFS gets a lifecycle policy (`transition_to_ia` after 30 days,
    `transition_to_primary_storage_class` on next access) to move the
    world's storage to cheaper Infrequent Access while idle — pure saving,
    no availability tradeoff, so this one isn't a toggle.

## Inspiration repo

<https://github.com/AndresArcones/minecraft-aws-ondemand>
