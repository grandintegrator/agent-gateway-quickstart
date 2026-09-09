# Agent Gateway quickstart — Terraform

One root module that creates everything the scripts in the repo root create,
in dependency order, in a single `terraform apply`.

## What it creates

| Step | Resources | Notes |
|------|-----------|-------|
| APIs | `google_project_service` ×9 | `disable_on_destroy = false` |
| 1a gateway | `google_network_services_agent_gateway` | `AGENT_TO_ANYWHERE`, pointed at the **regional** registry |
| 1b enforcement | `google_network_services_authz_extension` + `google_network_security_authz_policy` | `iap.googleapis.com`; `var.enforcement_mode` = `DRY_RUN` (log only, fail open) or `ENFORCED` |
| 1c allowlist | `google_agent_registry_service` ×11 | the baseline Google API hosts, `.mtls.` variants included |
| 1d grant | `google_iap_agent_registry_iam_member` | `roles/iap.egressor` for every agent in the project |
| 2 MCP server | `google_artifact_registry_repository`, `terraform_data.mcp_build`, `google_cloud_run_v2_service` | image built from `../mcp-server` with Cloud Build buildpacks (**local-exec**), or `var.mcp_image` |
| 4 register + grant | `google_agent_registry_service` (with `tools.json`), `google_iap_agent_registry_mcp_server_iam_member` | per-tool authorization possible, per-agent grant |
| 3 agent | `google_vertex_ai_reasoning_engine` | `../agent` tarred at plan time, source-based deploy, `AGENT_IDENTITY`, bound to the gateway, `MCP_URL` env |
| 3 IAM | `google_project_iam_member` | `roles/aiplatform.user` for the agent's principal (LLM access) |
| 6 Gemini Enterprise | `google_project_iam_member` ×2, `terraform_data.ge_agent` | registration via `scripts/ge_agent.sh` (**local-exec**, upsert on apply, delete on destroy); only when `gemini_enterprise_app_id` is set |

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # at least project_id
terraform init
terraform apply
```

Requirements on the machine running Terraform: `gcloud` authenticated (used by
the two local-exec steps and for Application Default Credentials), `bash`,
`tar`, `python3`, `curl`.

Timings seen in testing: gateway ~3 min, image ~1 min, agent ~12 min (it is a
container build plus a deploy). Registry entries take ~4 min to reach the
gateway, so give the first agent call a moment after apply.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `project_id` | — | required |
| `location` | `us-central1` | gateway, registry, MCP server and agent all live here |
| `org_id` | read from project | for the Agent Identity trust domain |
| `gateway_id` | `demo-egress-gw` | |
| `enforcement_mode` | `DRY_RUN` | `ENFORCED` once the logs are clean; in-place update |
| `mcp_service_name` | `demo-weather-mcp` | Cloud Run service and registry id |
| `mcp_image` | build it | prebuilt image to skip Cloud Build |
| `mcp_invoker_iam_disabled` | `true` | org policies usually forbid `allUsers`; `false` adds that binding instead |
| `deploy_agent` | `true` | `false` = gateway + MCP only |
| `agent_display_name` | `gateway-demo-adk-agent` | |
| `agent_model` | `gemini-2.5-flash` | |
| `gemini_enterprise_app_id` | `""` | engine id of an existing app; empty skips step 6 |
| `gemini_enterprise_location` | `global` | `global`, `us` or `eu` |
| `gemini_enterprise_project_number` | this project | if the app lives elsewhere |
| `gemini_enterprise_display_name` / `_description` | demo strings | what users see |
| `publish_to_all_users` | `false` | `true` = `ENABLED` for all app users, else `PRIVATE` |

## After apply

```bash
terraform output                                 # gateway, mcp_url, agent_resource_name, agent_principal
cd .. && ./1-setup-gateway.sh logs 15m           # verdicts (set PROJECT_ID / LOCATION / GATEWAY_ID to match)
```

To ask the agent something the way Gemini Enterprise does:

```bash
AGENT=$(terraform output -raw agent_resource_name)
curl -sS -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" \
  "https://$(terraform output -raw location 2>/dev/null || echo us-central1)-aiplatform.googleapis.com/v1beta1/${AGENT}:streamQuery" \
  -d '{"class_method":"stream_query","input":{"user_id":"demo","message":"What is the weather in Melbourne?"}}'
```

## Mapping to the scripts, and sharp edges

- Names match the scripts (`allow-*` registry ids, `<gateway>-iap-authzextension`,
  `<gateway>-iap-authzpolicy`), so a stack created by the scripts can be
  `terraform import`ed rather than recreated. That matters because the
  registry rejects a URL that is already registered under a *different* id —
  with an empty error message.
- `source_archive` is input-only, so Terraform cannot diff the agent code. The
  `AGENT_SOURCE_SHA` env var carries a digest of `../agent` and forces the
  redeploy (~12 min) when the code changes.
- `class_methods` (`../agent/class_methods.json`) must be declared for
  source-based deploys, or `:streamQuery` is not exposed and Gemini Enterprise
  cannot call the agent. Regenerate it when you bump `google-adk`:
  `python -c "import json; from google.adk.cli.cli_deploy import _AGENT_ENGINE_CLASS_METHODS as C; json.dump(C, open('agent/class_methods.json','w'), indent=2)"`.
- `google_project_iam_member` is non-authoritative on create but does remove
  the binding on destroy. If the Discovery Engine service agent (or anything
  else) already held `roles/aiplatform.user` / `roles/aiplatform.viewer`
  before you applied, `terraform state rm` those members before `destroy`, or
  re-grant afterwards.
- Gemini Enterprise registration assigns a licence seat to the creator. A
  full licence config fails with `FAILED_PRECONDITION: ... reached license
  config quota`; that is a seat problem, not a Terraform one.
- Destroy order is handled by the graph: registration → agent → registry
  entries → Cloud Run → policy → extension → gateway. The agent delete takes a
  few minutes.
