# Gemini Enterprise registration + Terraform implementation — design

Date: 2026-09-09. Status: implemented and validated live the same day (see the PR description for what was exercised).

## Goal

Extend the Agent Gateway quickstart so that:

1. an agent governed by the gateway can be **registered into a Gemini Enterprise
   app** and used from the Gemini Enterprise UI, with its MCP calls still
   flowing through (and being authorized by) the gateway, and
2. the whole stack can be stood up with **one `terraform apply`** from a new
   `terraform/` folder.

The existing shell/Python path (steps 1–5, trivial no-LLM agent) stays as it
is. It is the teaching path and has been validated live; we add to it, we do
not change it.

## Why an ADK agent is required

Gemini Enterprise's ADK registration invokes the agent through
`reasoningEngines:streamQuery`, which dispatches to the ADK template's
`streaming_agent_run_with_events`. The repo's `GatewayDemoAgent` exposes only
a custom `query(url, tool, arguments)` method, so it cannot be driven from the
Gemini Enterprise UI. A small ADK `LlmAgent` is therefore added as a second,
optional agent.

## Part A — scripts path

### New: `agent/` (ADK agent source, shared by scripts and Terraform)

```
agent/
  __init__.py          # from . import agent
  agent.py             # root_agent = LlmAgent(...)
  requirements.txt     # google-adk[mcp], google-cloud-aiplatform[agent_engines]
```

- `root_agent`: `LlmAgent`, model `gemini-2.5-flash`, instruction: weather
  assistant that MUST use the MCP tools for weather and may use `fetch_url` for
  anything else.
- Tools:
  - `McpToolset(StreamableHTTPConnectionParams(url=MCP_URL))` — `MCP_URL`
    comes from the environment (set at deploy time). This is the **ALLOWED**
    path through the gateway.
  - `fetch_url(url)` — plain HTTPS GET, returns status + first 500 chars. This
    is the **DENIED** path (unregistered host), so the gateway verdict can be
    demonstrated from the Gemini Enterprise UI too.
- No session/memory customisation: the Agent Engine `AdkApp` template's
  defaults are used (managed sessions), so nothing else needs allowlisting
  beyond the existing baseline.

Pins: ADK 2.x no longer depends on `mcp`; the agent pins `google-adk[mcp]`
(which resolves `mcp>=1.24,<2`). The MCP *server* keeps `mcp>=2,<3`. The two
never share an environment.

### Changed: `2-deploy-agent.py`

Adds three sub-commands; existing ones are untouched.

| Command | What it does |
|---|---|
| `deploy-adk` | `client.agent_engines.create(config={source_packages:["agent"], entrypoint_module:"agent.agent", entrypoint_object:"root_agent", requirements_file:"agent/requirements.txt", agent_framework:"google-adk", class_methods:<ADK 13>, env_vars:{MCP_URL}, identity_type:"AGENT_IDENTITY", agent_gateway_config:{...}, display_name:"gateway-demo-adk-agent"})` then grants the new agent's principal `roles/aiplatform.user` on the project (LLM access — the trivial agent never needed it). |
| `chat-adk "question"` | Calls `:streamQuery` (`stream_query` with `user_id`/`message`) and prints the final text — same code path Gemini Enterprise uses, so it proves the agent works before registering it. |
| `teardown-adk` | Deletes the ADK agent. |

`verify`/`_agent_id` gain an optional `AGENT_DISPLAY_NAME` env override so the
same plumbing works for either agent (default stays `gateway-demo-agent`).

### New: `4-register-gemini-enterprise.sh`

```
./4-register-gemini-enterprise.sh grant      # iap.egressor for the ADK agent on the MCP server (reuses 3-register-mcp.sh grant with AGENT_DISPLAY_NAME)
./4-register-gemini-enterprise.sh register   # POST/PATCH assistants/default_assistant/agents (ADK definition)
./4-register-gemini-enterprise.sh publish    # PATCH sharingConfig.scope=ALL_USERS (PRIVATE -> ENABLED)
./4-register-gemini-enterprise.sh status
./4-register-gemini-enterprise.sh remove
```

- Config: `GE_APP_ID` (engine id, e.g. `my-app_1234`), `GE_LOCATION`
  (`global`|`us`|`eu`, default `global`), `GE_PROJECT_NUMBER` (defaults to
  `PROJECT_NUMBER`). Endpoint: `https://discoveryengine.googleapis.com` for
  global, `https://{loc}-discoveryengine.googleapis.com` otherwise.
- Payload (mirrors what `agents-cli publish gemini-enterprise` sends):
  `displayName`, `description`, `icon.uri`,
  `adkAgentDefinition.provisionedReasoningEngine.reasoningEngine`,
  optional `adkAgentDefinition.toolSettings.toolDescription` (kept only if
  the API accepts it — verified live during implementation).
- Idempotent: `register` lists agents, matches on `reasoningEngine`, PATCHes
  if found, else POSTs.
- Headers: `Authorization`, `x-goog-user-project: PROJECT_ID`.
- Prerequisite IAM (done by `grant`): the Discovery Engine service agent
  `service-PROJECT_NUMBER@gcp-sa-discoveryengine.iam.gserviceaccount.com`
  gets `roles/aiplatform.user` + `roles/aiplatform.viewer` on the project so
  Gemini Enterprise can call the reasoning engine.

### README

New **Step 6 — put the agent in Gemini Enterprise**, plus a **Terraform**
section pointing at `terraform/README.md`, plus gotchas learned during
implementation (LLM agents on Agent Identity need `aiplatform.user`; ADK 2.x
`mcp` extra; sharing scope).

## Part B — `terraform/`

Single root module, opinionated quickstart (not a reusable module library).

```
terraform/
  versions.tf            # terraform >= 1.9, google ~> 8.2 (google-beta only if a field forces it)
  variables.tf           # project_id, org_id, location, gateway_id, enforcement_mode, mcp_service_name,
                         # mcp_image (optional override), deploy_agent (bool), agent_display_name,
                         # gemini_enterprise_app_id (optional), gemini_enterprise_location, publish_to_all_users
  apis.tf                # google_project_service for aiplatform, networkservices, networksecurity, iap,
                         # agentregistry, run, artifactregistry, cloudbuild, discoveryengine
  gateway.tf             # google_network_services_agent_gateway (AGENT_TO_ANYWHERE, regional registry)
  authz.tf               # google_network_services_authz_extension (iap.googleapis.com, metadata
                         # iamEnforcementMode=var.enforcement_mode, failOpen = DRY_RUN) +
                         # google_network_security_authz_policy (CUSTOM / REQUEST_AUTHZ)
  registry.tf            # baseline allowlist: for_each google_agent_registry_service (same 11 hosts as
                         # 1-setup-gateway.sh) + google_iap_agent_registry_iam_member (project principalSet)
  mcp-server.tf          # Artifact Registry repo; terraform_data local-exec `gcloud builds submit --pack`
                         # (skipped when var.mcp_image set); google_cloud_run_v2_service (invoker_iam_disabled);
                         # google_agent_registry_service with mcp-server/tools.json
  agent.tf               # data.external tarball of ../agent; google_vertex_ai_reasoning_engine
                         # (source_code_spec.inline_source + python_spec, agent_framework google-adk,
                         # class_methods from adk_class_methods.json, identity_type AGENT_IDENTITY,
                         # deployment_spec.env MCP_URL, agent_gateway_config.agent_to_anywhere_config);
                         # google_iap_agent_registry_mcp_server_iam_member (this agent -> this MCP server);
                         # google_project_iam_member aiplatform.user for principal://<effective_identity>
  gemini-enterprise.tf   # count = app id set ? 1 : 0; IAM for discoveryengine service agent;
                         # terraform_data + scripts/ge_agent.sh (create/update on apply, delete on destroy,
                         # triggers on agent name/display/description/scope)
  outputs.tf             # gateway name, mcp url, agent resource name, agent principal, GE agent name
  adk_class_methods.json # the 13 ADK AdkApp operations (generated from google-adk)
  scripts/tar_b64.sh     # external data source: tar.gz + base64 + sha of a directory
  scripts/ge_agent.sh    # idempotent GE registration used by terraform_data
  terraform.tfvars.example
  README.md
```

Design decisions:

- **Native resources wherever they exist.** Gateway, authz extension/policy,
  registry services, IAP egressor IAM (registry-wide and per MCP server),
  Cloud Run v2, Artifact Registry, reasoning engine — all first-class in
  provider 8.x. Only two things fall back to `local-exec`: the Cloud Build
  buildpack image (no native "build from source" for a plain Cloud Run
  service in the GA provider) and the Gemini Enterprise agent (no resource).
- **Source-based agent deploy, no pickles.** `data "external"` tars `../agent`
  at plan time and hands the base64 to `inline_source.source_archive`; the
  sha is included so code changes trigger a redeploy.
- **Ordering that the API does not enforce.** `depends_on` so that the
  baseline registry entries and the registry-wide egressor grant exist before
  the agent is created (otherwise the deploy fails ~13 min later), and so
  the gateway exists before the authz policy targets it.
- **Enforcement mode is a variable.** `DRY_RUN` (default, `fail_open=true`)
  or `ENFORCED` (`fail_open=false`). Flipping it is an in-place update of the
  extension — same as `1-setup-gateway.sh enforce`.
- **Gemini Enterprise app is an input, not a resource.** Matches Google's
  own tooling assumption (app must pre-exist). Registration is created only
  when `gemini_enterprise_app_id` is set.
- **Destroy works.** Reasoning engine `deletion_policy`/force delete; the
  GE `terraform_data` runs `ge_agent.sh delete` on destroy; Cloud Run
  `deletion_protection = false`; bucket/AR `force_destroy`.

## Error handling / known sharp edges (to document, not paper over)

- Registry URL uniqueness: registering a URL already registered under a
  different service id fails with an empty error. The TF names match the
  script names so import is possible, and the README says so.
- Reasoning engine create is 8–15 min; TF timeouts set to 30 min.
- Registry propagation to the gateway is ~4 min; first call after apply may
  still be `UNREGISTERED`.
- Agent Identity token exchange calls `iamcredentials(.mtls)`; both are in
  the baseline.

## Testing (live, in `ajmalaziz-814-20250326021733`)

Scripts path (us-east1, existing gateway `demo-egress-gw`, existing MCP server):
1. `python 2-deploy-agent.py deploy-adk` → `chat-adk "weather in Melbourne?"` returns
   canned weather; `1-setup-gateway.sh logs` shows ALLOWED for the MCP host.
2. `chat-adk "fetch https://api.github.com/zen"` → DENIED logged (blocked, gateway ENFORCED).
3. `4-register-gemini-enterprise.sh register` against app `demo_1753333559301`;
   `status` shows the agent; a `:streamAssist` call (or UI) answers via the agent.
4. `remove` / `teardown-adk` clean up.

Terraform path (us-central1 — its registry is empty, so no URL collisions):
1. `terraform init/validate/plan`, `apply` with a `tf-` prefixed gateway id and
   MCP service name, GE app `demo_1753333559301`.
2. Same three functional checks as above via outputs.
3. `terraform destroy` leaves nothing behind (verify with list calls).

Then: branch `feat/gemini-enterprise-terraform`, commit (no co-author
trailer), push, `gh pr create`.

## Out of scope

- Replacing the trivial agent with the ADK agent.
- Creating the Gemini Enterprise app itself.
- OAuth `authorizationConfig` for the agent.
- PSC / network attachment egress on the gateway (variables could be added
  later; the provider supports it).
