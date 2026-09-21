# Project plan: CDK → Terraform port

Rebuild [`minecraft-aws-ondemand`](https://github.com/AndresArcones/minecraft-aws-ondemand)
(CDK) as a Terraform project that keeps the on-demand behaviour and cost
model of the original, while fixing the Cloudflare-parent DNS assumption and
tightening IAM, secrets, and observability.

**In scope:** full infra port, optional Cloudflare NS delegation,
least-privilege IAM, CI checks, world-data migration.
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

| ID | Task | Depends on | Est | Status |
|---|---|---|---|---|
| 2.1 | Split IAM: least-priv launcher role + scoped watchdog task role | 1.3, 1.4 | 3h | ✅ done |
| ~~2.2~~ | ~~Twilio creds → Secrets Manager; wire Twilio SMS Lambda~~ — dropped, see Decisions | — | — | — |
| 2.3 | Upgrade launcher Lambda to Python 3.13; make idempotent | 1.4 | 1.5h | ✅ done |
| 2.4 | Pin both containers by digest; log retention | 1.3 | 1h | ⬜ log retention done (Phase 1); digest pinning still open |
| 2.5 | `observability`: CloudWatch dashboard + start/idle/error alarms | 1.8 | 3h | ✅ done — opt-in via `var.enable_observability` (default `false`), see Decisions |
| 2.6 | CI: add `tflint` + tfsec/Checkov + `plan` on PR | 0.5 | 2h | ⬜ `tflint`/Checkov done; live `plan` on PR deliberately deferred (needs OIDC, declined for now) |
| 2.7 | README: variables, deploy, manual-start fallback, teardown | all | — | ✅ done |
| 2.8 | Re-run functional test on hardened stack | 2.1–2.6 | 1.5h | ⬜ pending — needs a real `apply` first |

**Phase 3 — Improved trigger (optional, ~6–8h)**

| ID | Task | Depends on | Est | Status |
|---|---|---|---|---|
| 3.1 | Lambda Function URL → `desired_count=1` | 2.1 | 2h | ✅ done (`var.enable_start_api`) — start-only, shared-secret token instead of AWS auth |
| 3.2 | Cloudflare Worker behind Access as start endpoint | 3.1 | 3h | ❌ declined — see Decisions; the raw Function URL is good enough |
| 3.3 | Retire query-log trigger; keep watchdog for scale-down | 3.2 | 1h | ⬜ not started — the start API is additive, not a replacement, for now |

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
- **Launcher Lambda runtime was Python 3.12** (not the CDK original's 3.8,
  no longer creatable on Lambda) — bumped to 3.13 in task 2.3.
- **RCON (25575/tcp) ingress rule removed (task 2.1):** it was open to
  `0.0.0.0/0` on the service security group, ported as-is from the CDK
  original. Unnecessary — the watchdog's readiness check
  (`minecraft-ondemand/minecraft-ecsfargate-watchdog/watchdog.sh`) runs a
  local `netstat` against 25575, not a network connection, and Fargate
  `awsvpc` tasks share one network namespace across their containers, so
  same-task traffic never crosses the ENI/security group boundary anyway.
  Nothing else needs this port reachable, so the rule is gone rather than
  scoped down.
- **AWS provider pinned to `~> 5.0`, not v6, initially** — v6 renamed
  several attributes (e.g. `aws_region.name` → `aws_region.region`) and
  likely had other breaking changes across the resources this project
  uses. Stayed on 5.x deliberately: "revisit as a deliberate upgrade
  later, not an incidental one." Superseded during Phase 3 — see below.
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

## Decisions locked in during Phase 2

- **Ran Checkov locally as a first pass on task 2.1/2.6** (ad hoc, not yet
  wired into CI — that's still task 2.6 proper): 28 findings. Fixed 8 that
  were free or near-free with no functional tradeoff: security group rule
  descriptions, SNS topic encryption via the free AWS-managed key
  (`alias/aws/sns`), locking down each VPC's auto-created default security
  group to deny-all (only in the create-VPC path — never touched if
  `vpc_id` is set), and a lifecycle policy on the state bucket (expire
  noncurrent versions after 90 days, abort incomplete multipart uploads
  after 7).
- **Attempted but reverted: launcher Lambda `reserved_concurrent_executions
  = 1`.** Good idea in principle (only one concurrent invocation is ever
  useful), but this AWS account's total Lambda concurrency quota is too low
  — AWS requires at least 10 unreserved concurrent executions across the
  whole account, and reserving even 1 for this function violated that
  floor on apply. Revisit once/if the account's quota is raised (a support
  request, not something Terraform controls).
- **The other 20 findings are intentionally not fixed** — each one either
  costs real recurring money for a threat model that doesn't justify it
  (customer-managed KMS keys for CloudWatch/EFS/S3, 1-year log retention,
  Lambda DLQ/VPC placement/X-Ray/code-signing, S3 cross-region replication
  and access logging, Route 53 DNSSEC), or directly contradicts an
  already-made architecture call (public subnets / no NAT gateway — the
  "ECS service and subnets shouldn't have public IPs" findings are exactly
  the cost-creep risk already listed in the Risks table), or is a false
  positive for this design (the placeholder A record "has no attached
  resource" — that's the watchdog's job at runtime, by design).
- **Task 2.1 finished: RCON ingress rule removed** rather than scoped down
  — see the Phase 1 decision above. Reintroduced as an opt-in toggle,
  `var.rcon_allowed_cidrs` (default `[]`, no rule created): a `for_each`
  ingress rule per CIDR on `modules/ecs`, for the case where you later want
  to run admin commands yourself (`mcrcon`) from a known IP. Deliberately
  no `0.0.0.0/0` shortcut — RCON auth is a plaintext password over TCP, so
  the variable only accepts specific CIDRs.
- **Task 2.6 (partial): `tflint` + Checkov wired into CI**, gated on
  `.tf`/`.tflint.hcl`/`.checkov.yaml` changes alongside the existing
  `fmt`/`validate` job. Checkov reads `.checkov.yaml`, whose `skip-check`
  list is exactly the 19 (of the 20) findings above still present in the
  codebase — the 20th, RCON, is fixed. One check unrelated to that Phase 2
  Checkov pass showed up once `tflint` started running for real:
  `CKV_AWS_394` (`aws_availability_zones` not pinning zone identity) —
  triaged and accepted, see "Beyond the milestone plan" below for why.
  Fixing `tflint`'s own findings (every module's `versions.tf` was
  missing `required_version` and a provider version constraint) surfaced a
  separate, pre-existing bug: each module's own `.terraform.lock.hcl` (used
  only when running `terraform init` standalone inside a module directory,
  e.g. via `just validate`) had drifted to AWS provider 6.65.0, while
  `envs/production`'s real lock file — the one that actually governs
  `apply` — stayed on 5.100.0 per the "stay on 5.x" decision above. Adding
  the constraint forced the drifted per-module lock files to be
  regenerated back onto 5.x. Live infrastructure was never on 6.x; this
  was a standalone-validation-only inconsistency. Live-plan CI (running
  `terraform plan` against real AWS via OIDC) is deliberately out of scope
  for now — revisit when ready to grant GitHub Actions AWS access.
- **Task 2.3 done: launcher Lambda bumped to Python 3.13.** The handler
  (`modules/dns-trigger/lambda/lambda_function.py`) already had a
  check-then-act guard (only calls `update_service` when `desiredCount ==
  0`) from the first commit, which already makes it safe under retries —
  `update_service(desiredCount=1)` is an assignment, not an increment, so a
  redundant or concurrent invocation can't scale the service past 1 even
  without the check. Hardened two real gaps instead of re-deriving
  idempotency that was already there: an unhandled `IndexError` if
  `describe_services` ever returns no matching service (now a clear
  `RuntimeError`), and no visibility into `ClientError` failures before
  Lambda's automatic async-invoke retry kicks in (now logged before
  re-raising).

## Beyond the milestone plan

Small, non-milestone improvements picked up along the way — not gated on a
phase, just worth doing.

- **ECS Exec (`just console`):** `enable_execute_command = true` on the
  service, plus the task role permissions it needs (`ssmmessages:*` — no
  resource-level scoping possible, an AWS constraint; CloudWatch Logs
  actions scoped to a dedicated `/ecs/<cluster>/exec` log group, except
  `logs:DescribeLogGroups` which also can't be scoped). Session transcripts
  always log to that group — an audit trail for admin shell access, not
  gated behind `var.debug` since it's a security concern, not a debugging
  one. `initProcessEnabled = true` added to the minecraft-server container
  per AWS's recommendation, so exec sessions don't leave zombie processes
  behind. This is now the preferred way to run admin commands (`just
  console "rcon-cli list"`, using the itzg image's bundled `rcon-cli`) —
  IAM-authenticated over SSM, no security-group exposure at all, unlike
  the CIDR-based `rcon_allowed_cidrs`. Checkov's `CKV_AWS_224` (exec
  session logging without a customer-managed KMS key) joins the existing
  KMS skip-check bucket in `.checkov.yaml` — same cost reasoning as the
  rest of that bucket.
- **Cloudflare made optional (`var.manage_cloudflare_dns`, default
  `false`):** Cloudflare was only ever used for one thing — the 4 NS
  records that delegate the child zone `dns-trigger` creates. That child
  zone (and its query logging) is always needed regardless of who hosts
  `domain_name`'s authoritative DNS, since Route 53 query logging is what
  the DNS-trigger depends on — so nothing about the core design assumed
  Cloudflare specifically. `cloudflare_api_token`/`cloudflare_zone_id` got
  empty-string defaults plus a cross-variable `validation` block (needs
  Terraform ≥1.9, already required by `required_version >= 1.10.0`) that
  only requires them when the toggle is on; `cloudflare_record.ns_delegation`'s
  `count` gates on the same toggle. The `cloudflare` provider block itself
  stays configured unconditionally — Terraform requires every provider a
  resource block references to be configured even when that resource's
  count is 0. An empty token is *not* harmless there, though — verified
  against the real provider: it validates `api_token`'s shape (40+ chars,
  `a-zA-Z0-9_-`) during `Configure`, before any resource is even
  considered, so an empty string breaks `plan`/`apply` outright regardless
  of `manage_cloudflare_dns`. `local.cloudflare_api_token` in
  `providers.tf` substitutes an obviously-fake 41-char placeholder
  whenever the real variable is empty, satisfying that check without ever
  being used for a real request. Scope deliberately stops at "toggle
  + manual delegation fallback" — non-Cloudflare users take the
  `hosted_zone_name_servers` output and add the NS record wherever their
  DNS lives, same one-time step regardless of host (including Route 53
  itself). A more automated Route 53-native delegation path (auto-creating
  the NS record in an existing parent Route 53 zone) was considered and
  deliberately deferred — meaningfully more code for one specific case that
  a five-minute manual step already covers.
- **`just logs-minecraft` / `just logs-watchdog`:** both log groups already
  existed behind `var.debug` (task 1.x) but had no `just` recipe to tail
  them — `logs-dns`/`logs-launcher` covered the DNS-trigger path only.
  Needed new module outputs (`minecraft_log_group_name`,
  `watchdog_log_group_name`, `null` when `var.debug` is false, same
  index-guard pattern as `local.mc_log_config` in `modules/ecs/main.tf`).
  The recipes themselves hit a real gotcha worth recording: a `null`
  Terraform output isn't stored in state at all, and `terraform output
  -raw <name>` on a name that's absent from state prints a "No outputs
  found" warning **to stdout** and exits `0` — not an error, not on
  stderr, so neither `2>/dev/null` nor an exit-code check catches it, and
  after stripping punctuation the warning text reads as a non-empty
  "log group name". `terraform output -json <name>` behaves correctly
  instead (real error, stderr, exit `1`) for a missing/null output, so
  each recipe checks existence with `-json` first and only then trusts
  `-raw` for the value. Verified both branches against a real Terraform
  state before trusting this, not just reasoned about.
- **`CKV_AWS_394` triaged and accepted**, closing out the "not yet triaged"
  flag from task 2.6. Read Checkov's actual check source
  (`AWSAvailabilityZonesUnfiltered.py`) rather than guessing: it only
  passes an `aws_availability_zones` data source that carries an
  *identity*-based allowlist filter (`zone-name` or `zone-id` with literal
  values) — `state = "available"`, `all_availability_zones`, or a
  denylist (`exclude_names`/`exclude_zone_ids`) all still fail it, since
  each leaves the result open to a newly-added AZ leaking in. Satisfying
  it for real means hardcoding one specific region's AZ names into
  `modules/networking/main.tf` — directly breaking `var.aws_region`'s
  "works in any region" design (the README doesn't hardcode a region; the
  default is just `eu-west-2`). A variable-driven filter doesn't dodge
  this either: the check inspects whether `filter { name = "zone-id" }`
  is *literally present* in the code, regardless of what `values`
  evaluates to — so passing the scanner without hardcoding a region would
  mean shipping a filter with an empty `values` list by default, and the
  EC2 API itself rejects a filter with zero values. `var.max_azs` already
  bounds the blast radius of AWS adding a new AZ (caps subnet count; can't
  make more subnets appear), and any AZ-selection shift a new AZ did cause
  would show up in `terraform plan` output before ever reaching `apply` —
  this project has no unattended-apply path. Accepted, not fixed; added to
  `.checkov.yaml`'s "already-made architecture calls" bucket.
- **Task 3.1 done, 3.2 declined (`var.enable_start_api`, default `false`):**
  the Cloudflare Worker in 3.2 only ever existed to put a nicer URL in
  front of the Function URL from 3.1 — a raw `https://<id>.lambda-url.
  <region>.on.aws/` is fine when you're bookmarking it, not typing it, so
  3.2 (and by extension 3.3, which depended on it) is skipped rather than
  deferred-with-intent-to-build. Reuses the existing launcher Lambda
  instead of adding a second one — its handler already ignores the
  invoking event entirely and just does an idempotent "start if not
  started," so a `aws_lambda_function_url` pointed at the same function is
  just a second way to invoke the exact same logic, no duplication.
  Auth model was a real decision, not a default: `authorization_type =
  "NONE"` (no AWS SigV4 needed — the point is tapping a phone bookmark)
  gated instead by an app-level `?token=` query param checked in the
  handler against a Terraform-generated `random_password` (`special =
  false`, so it's URL-safe with no percent-encoding surprises). Considered
  and rejected: `AWS_IAM` auth (secure, but defeats "tap from phone" —
  needs a SigV4-signed request, no plain browser hit) and fully-open with
  no token (simplest, but zero gatekeeping on a URL that can trigger real
  — if cheap — spend). `CKV_AWS_258` (Function URL AuthType NONE) is
  skipped in `.checkov.yaml` for exactly this reason; currently a no-op
  for CI since `count = 0` while the default stays false. Explicitly
  start-only, per your call — stop stays `just stop`/idle timeout for now,
  revisit later if wanted.
- **Start API 403'd on first real test — AWS added a second mandatory
  permission requirement, provider bumped to fix it.** After apply, the
  bookmarked URL returned `403 {"Message":"Forbidden...}` — traced (via
  live `get-function-url-config`/`get-policy`/`curl -v` against the real
  resource, not guesswork) to a genuine AWS Lambda platform change:
  starting October 2025 (fully enforced November 1, 2026 — we're mid
  rollout now), a public Function URL's resource policy needs **both**
  `lambda:InvokeFunctionUrl` **and** `lambda:InvokeFunction` (the second
  scoped via `invoked_via_function_url = true`) — our original single
  statement matched the pre-October-2025 requirement only. The Terraform
  argument for the second statement doesn't exist before provider
  **v6.28.0**, which forced the question this project had been deferring:
  bump `~> 5.0` to `~> 6.0` now, shell out to the AWS CLI via
  `local-exec`, or shelve the feature. Chose the bump. Audited every
  module against HashiCorp's official v6 upgrade guide (not just the
  breaking changes that happened to come up in search results) before
  touching anything: the *only* affected code in this entire project was
  `data.aws_region.current.name` → `.region` (3 call sites in
  `modules/ecs/main.tf`, 1 in `modules/dns-trigger/main.tf`) — nothing
  else in the full breaking-changes list (removed OpsWorks/SimpleDB/
  Worklink resources, `aws_eip`'s `vpc` arg, strict booleans, Redshift
  default flips, a long list of resource/data-source attribute renames)
  touches anything this project uses; verified with a targeted grep for
  every resource/data type in the codebase plus a search for legacy
  `"1"`/`"0"` string-booleans (none found). All 7 `versions.tf`/inline
  `terraform{}` blocks bumped to `~> 6.0`, every lock file regenerated
  fresh (`-upgrade`, not hand-edited) resolving to `6.65.0`, every module
  and root re-validated clean against the real provider before trusting
  any of this. Along the way, also found (via a live `curl` test) a
  duplicate, non-Terraform-managed `FunctionURLAllowPublicAccess`
  resource-policy statement on the function — AWS Console's own
  auto-generated name when toggling Function URL auth type there,
  presumably added while looking into the original 403. Removed it
  (`aws lambda remove-permission`) since Terraform doesn't own it and two
  overlapping public-access grants isn't a state worth leaving around,
  though it turned out not to be the actual cause. `CKV_AWS_301` joined
  `CKV_AWS_258` in `.checkov.yaml` once local testing (with
  `enable_start_api = true` actually set — Checkov reads the real
  `terraform.tfvars` off disk regardless of `.gitignore`) exercised the
  second permission statement for the first time.

- **Task 2.5 done: `observability` module, opt-in via `var.enable_observability`
  (default `false`).** Not everyone wants the extra CloudWatch line item, so
  the whole module is gated with `count` at the call site in
  `envs/production/main.tf` rather than threading an `enabled` flag through
  every resource inside it — the module itself has no notion of being
  "off." Three alarms plus one dashboard:
  - Launcher Lambda `Errors` and (when `discord_webhook_url` is set)
    Discord-notify Lambda `Errors` — straightforward, `treat_missing_data =
    "notBreaching"` so a quiet function doesn't itself alarm.
  - A "long-running" safety net, not a gameplay alarm: `AWS/ECS`
    `CPUUtilization` is only published while the service has a running
    task, so `datapoints_to_alarm` consecutive hourly periods of *any*
    data (threshold `-1`, since CPU% is never negative — this alarms on
    data being *present*, not on load) means the task has been up
    continuously that whole time without scaling back to zero. Catches a
    stuck watchdog (a Spot interruption mid-shutdown, a crash) racking up
    charges silently — exactly the kind of thing a cost-conscious,
    scale-to-zero project should want a tripwire for. Tunable via
    `var.long_running_alarm_hours` (default 6h) since "normal" session
    length varies.
  - Dashboard has two widgets unconditionally (ECS CPU/memory, launcher
    Lambda invocations/errors) plus a third for the Discord-notify Lambda,
    added via `concat()` only when that function exists — a dashboard
    widget pointing at a nonexistent function's metrics wouldn't error,
    it'd just render empty, so this keeps it clean rather than leaving a
    dead panel.
  - Alarms publish to the same SNS topic `modules/notifications` already
    owns (`sns_topic_arn`) rather than standing up a second notification
    channel — so alarm state changes fan out to whichever of
    email/Discord you already have configured, or nowhere (alarms still
    exist and show in the console) if neither is set.
  - No new Checkov findings — verified locally (`checkov -d
    modules/observability`); metric alarms and dashboards aren't the kind
    of resource Checkov's AWS ruleset has much to say about.
  - Not done: the dashboard JSON couldn't be verified against a real
    `apply` (no AWS credentials in the environment this was built in) —
    the widget schema used (`type: "metric"`, `metrics` array of
    `[Namespace, MetricName, DimName, DimValue, ..., {options}]`) is
    CloudWatch's long-stable, well-documented format, not a newer surface
    like the Discord Components V2 work above, so confidence is high, but
    it's still first-apply-unverified.
  - A follow-up whole-repo Checkov run (not just `modules/observability`
    in isolation) turned up `CKV_AWS_65` (ECS Container Insights) —
    pre-existing, not caused by this module: the *previous* session's cost
    pass turned `container_insights` off by default but never re-ran
    Checkov against that change. Triaged and skipped (same "AWS-managed
    over cost" bucket as everything else in `.checkov.yaml`), since
    `enable_observability`'s dashboard already covers CPU/memory without
    it.

- **AWS Backup added as a new opt-in `backup` module, `var.enable_backup`
  (default `false`).** Same "small real cost, not everyone wants it"
  reasoning and `count`-on-the-module-call pattern as `observability`
  above. Backs up the world-data EFS volume on a schedule you pick
  (`backup_days_of_week`, e.g. `["SUN"]` or `["MON", "THU"]`; `backup_hour`,
  UTC) via a 6-field AWS Backup cron (`cron(0 H ? * DAYS *)`), retained for
  `backup_retention_days` (default 30) before AWS Backup deletes the
  recovery point automatically. Deliberately distinct from the EFS
  lifecycle policy already in `modules/storage` — that's a storage-*class*
  optimization (Standard → IA after 30 days idle), not backup history; it
  does nothing for "I deleted the wrong thing" or a corrupted world.
  IAM role only gets `AWSBackupServiceRolePolicyForBackup`, not the
  restore policy too — restoring is a rare, manual, "you're already in the
  console for this" action, not something worth standing permission for.
  Backup vault uses the AWS-managed `aws/backup` key (`CKV_AWS_166` added
  to `.checkov.yaml`, same KMS-cost bucket as everything else there); the
  EFS filesystem itself is deliberately not enrolled in a backup plan when
  `enable_backup` is false, which fails `CKV2_AWS_18` by design — added to
  `.checkov.yaml` alongside the others that trade a Checkov pass for an
  explicit cost choice.

## Inspiration repo

<https://github.com/AndresArcones/minecraft-aws-ondemand>
