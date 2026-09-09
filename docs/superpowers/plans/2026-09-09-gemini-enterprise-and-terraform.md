# Gemini Enterprise registration + Terraform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an ADK agent that can be registered into a Gemini Enterprise app (scripts path) and a `terraform/` root module that stands up the whole gateway + MCP + agent + registration stack in one apply.

**Architecture:** A new `agent/` package (ADK `LlmAgent` + `McpToolset` + `fetch_url`) is the one artefact shared by both paths. Scripts gain `deploy-adk`/`chat-adk`/`teardown-adk` and a new `4-register-gemini-enterprise.sh`. Terraform uses native provider resources for everything except the Cloud Build image and the Gemini Enterprise agent, which use `terraform_data` + local-exec.

**Tech Stack:** bash + curl + python3 (scripts), `google-cloud-aiplatform[agent_engines]` 2.x (`agentplatform.Client`), `google-adk[mcp]` 2.x, Terraform >= 1.9, `hashicorp/google` ~> 8.2, `hashicorp/external`.

**Spec:** `docs/superpowers/specs/2026-09-09-gemini-enterprise-and-terraform-design.md`

## Global Constraints

- Existing steps 1–5 and `GatewayDemoAgent` are not changed in behaviour.
- The ADK agent pins `google-adk[mcp]` (mcp 1.x); the MCP server keeps `mcp>=2,<3`.
- Agent display name for the ADK agent: `gateway-demo-adk-agent`.
- All live tests run in project `ajmalaziz-814-20250326021733`; scripts path in `us-east1` (gateway `demo-egress-gw`, MCP `https://demo-weather-mcp-812402096883.us-east1.run.app/mcp`), Terraform path in `us-central1` with `tf-` prefixed names; Gemini Enterprise app `demo_1753333559301` (global).
- Commits: no co-author trailer. Work on branch `feat/gemini-enterprise-terraform`; open a PR, do not push to `main`.

---

### Task 1: ADK agent source (`agent/`) + local smoke test

**Files:**
- Create: `agent/__init__.py`, `agent/agent.py`, `agent/requirements.txt`, `agent/class_methods.json`

**Interfaces:**
- Produces: module `agent.agent` exposing `root_agent` (ADK `LlmAgent`); env `MCP_URL` (MCP endpoint), optional `MODEL` (default `gemini-2.5-flash`). `agent/class_methods.json` = the 13 ADK `AdkApp` operations, consumed by Task 2 and Task 4.

- [x] **Step 1: write the package**

`agent/__init__.py`:
```python
from . import agent  # noqa: F401  (ADK convention: the package exposes `agent.root_agent`)
```

`agent/agent.py`:
```python
"""The ADK agent used for the Gemini Enterprise step (and by terraform/).

Two tools, one per gateway verdict:
  - the MCP toolset for the dummy weather server (registered + granted => ALLOWED)
  - fetch_url, a plain HTTPS GET to any host (unregistered => DENIED)
"""
import os
import urllib.request

from google.adk.agents import LlmAgent
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.adk.tools.mcp_tool.mcp_toolset import McpToolset

MCP_URL = os.environ.get("MCP_URL", "https://your-mcp-server.example.com/mcp")
MODEL = os.environ.get("MODEL", "gemini-2.5-flash")


def fetch_url(url: str) -> dict:
    """Fetch a URL with a plain HTTPS GET and return the status and the first 500 characters."""
    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            return {"url": url, "reached": True, "status": resp.status,
                    "body": resp.read(500).decode(errors="replace")}
    except Exception as exc:
        return {"url": url, "reached": False, "error": f"{type(exc).__name__}: {exc}"[:300]}


root_agent = LlmAgent(
    name="gateway_demo_adk_agent",
    model=MODEL,
    description="Weather assistant whose outbound calls are governed by Agent Gateway.",
    instruction=(
        "You are a weather assistant. For any weather or forecast question you MUST call the "
        "get_weather or get_forecast tool and answer from its result. If the user asks you to "
        "fetch or open a URL, call fetch_url with that exact URL and report the outcome, including "
        "any error verbatim. Keep answers to two sentences."
    ),
    tools=[
        McpToolset(connection_params=StreamableHTTPConnectionParams(url=MCP_URL)),
        fetch_url,
    ],
)
```

`agent/requirements.txt`:
```
google-adk[mcp]>=2.8,<3
google-cloud-aiplatform[agent_engines]>=2.1,<3
```

- [x] **Step 2: generate `agent/class_methods.json` from the installed ADK**

```bash
cd ~/agent-gateway-quickstart && .venv/bin/python -c "
import json; from google.adk.cli.cli_deploy import _AGENT_ENGINE_CLASS_METHODS as C
json.dump(C, open('agent/class_methods.json','w'), indent=2); print(len(C))"
```
Expected: `13`.

- [x] **Step 3: local smoke test against the live MCP server**

```bash
cd ~/agent-gateway-quickstart && GOOGLE_GENAI_USE_VERTEXAI=1 GOOGLE_CLOUD_PROJECT=ajmalaziz-814-20250326021733 \
GOOGLE_CLOUD_LOCATION=us-east1 MCP_URL=https://demo-weather-mcp-812402096883.us-east1.run.app/mcp \
.venv/bin/python - <<'PY'
import asyncio
from google.adk.runners import InMemoryRunner
from google.genai import types
from agent.agent import root_agent
async def main():
    r = InMemoryRunner(agent=root_agent, app_name="t")
    s = await r.session_service.create_session(app_name="t", user_id="u")
    for q in ["What's the weather in Melbourne?", "Fetch https://api.github.com/zen"]:
        async for ev in r.run_async(user_id="u", session_id=s.id,
                                    new_message=types.Content(role="user", parts=[types.Part(text=q)])):
            if ev.is_final_response() and ev.content: print(q, "->", ev.content.parts[0].text)
asyncio.run(main())
PY
```
Expected: first answer mentions 22°C / sunny (canned data); second reports the GitHub zen text (no gateway locally).

---

### Task 2: `2-deploy-agent.py` — `deploy-adk`, `chat-adk`, `teardown-adk`

**Files:**
- Modify: `2-deploy-agent.py` (add after `teardown()`; extend the dispatch dict; `DISPLAY_NAME` env override)

**Interfaces:**
- Consumes: `agent/` from Task 1.
- Produces: env `AGENT_DISPLAY_NAME` respected by `_agent_id()`/`verify`; sub-commands `deploy-adk`, `chat-adk <text>`, `teardown-adk`. Constant `ADK_DISPLAY_NAME = "gateway-demo-adk-agent"`.

- [x] **Step 1: implement**

Change `DISPLAY_NAME = "gateway-demo-agent"` to `DISPLAY_NAME = os.environ.get("AGENT_DISPLAY_NAME", "gateway-demo-agent")` and add `ADK_DISPLAY_NAME = "gateway-demo-adk-agent"`, `ADK_MODEL = os.environ.get("MODEL", "gemini-2.5-flash")`.

Append:
```python
# ==============================================================================
# The ADK agent (agent/agent.py) — needed for Gemini Enterprise, which drives
# agents through :streamQuery. Deployed FROM SOURCE (no pickling), same two
# config entries as above, plus MCP_URL so the MCP toolset knows its server.
# ==============================================================================
def deploy_adk():
    import agentplatform

    class_methods = json.load(open(os.path.join(os.path.dirname(__file__), "agent", "class_methods.json")))
    client = agentplatform.Client(project=PROJECT_ID, location=LOCATION)
    remote = client.agent_engines.create(config={
        "display_name": ADK_DISPLAY_NAME,
        "description": "ADK weather agent governed by Agent Gateway",
        "staging_bucket": STAGING_BUCKET,
        "source_packages": ["agent"],
        "entrypoint_module": "agent.agent",
        "entrypoint_object": "root_agent",
        "requirements_file": "agent/requirements.txt",
        "agent_framework": "google-adk",
        "class_methods": class_methods,
        "env_vars": {"MCP_URL": MCP_URL, "MODEL": ADK_MODEL},
        "agent_gateway_config": {"agent_to_anywhere_config": {
            "agent_gateway": f"projects/{PROJECT_ID}/locations/{LOCATION}/agentGateways/{GATEWAY_ID}"}},
        "identity_type": "AGENT_IDENTITY",
    })
    name = remote.api_resource.name
    print("\nDEPLOYED:", name)

    # An LLM agent must be able to call Vertex AI. The trivial agent never
    # needed this; an ADK agent on Agent Identity does.
    principal = f"principal://{remote.api_resource.spec.effective_identity}"
    subprocess.run(["gcloud", "projects", "add-iam-policy-binding", PROJECT_ID,
                    f"--member={principal}", "--role=roles/aiplatform.user",
                    "--condition=None", "--quiet"], check=True, stdout=subprocess.DEVNULL)
    print("granted roles/aiplatform.user to", principal)
    print("\nNext: AGENT_DISPLAY_NAME=%s ./3-register-mcp.sh grant" % ADK_DISPLAY_NAME)


def _stream_query(agent_id: str, text: str) -> str:
    """The same call Gemini Enterprise makes: :streamQuery -> stream_query."""
    req = urllib.request.Request(
        f"{BASE}/{agent_id}:streamQuery",
        data=json.dumps({"class_method": "stream_query",
                         "input": {"user_id": "demo-user", "message": text}}).encode(),
        headers={"Authorization": f"Bearer {_token()}", "Content-Type": "application/json"})
    final = ""
    with urllib.request.urlopen(req, timeout=180) as resp:
        for line in resp:
            line = line.strip()
            if not line:
                continue
            ev = json.loads(line)
            for part in (ev.get("content") or {}).get("parts", []):
                if "text" in part:
                    final = part["text"]
                if "functionCall" in part:
                    print("  tool call:", json.dumps(part["functionCall"]))
    return final


def chat_adk():
    text = " ".join(sys.argv[2:]) or "What's the weather in Melbourne?"
    agent_id = _agent_id(ADK_DISPLAY_NAME)
    print(f"\n=== {ADK_DISPLAY_NAME} <- {text!r}")
    print(_stream_query(agent_id, text))
    print("\nGateway verdicts:  ./1-setup-gateway.sh logs 15m")


def teardown_adk():
    import agentplatform
    client = agentplatform.Client(project=PROJECT_ID, location=LOCATION)
    client.agent_engines.delete(
        name=f"projects/{PROJECT_ID}/locations/{LOCATION}/reasoningEngines/{_agent_id(ADK_DISPLAY_NAME)}",
        force=True)
    print("deleted", ADK_DISPLAY_NAME)
```

Change `_agent_id()` to `_agent_id(display_name: str = DISPLAY_NAME)` and use `display_name` in its body/exit message. Extend the dispatch dict with `"deploy-adk": deploy_adk, "chat-adk": chat_adk, "teardown-adk": teardown_adk`. Update the module docstring usage block.

- [x] **Step 2: live test (us-east1)**

```bash
cd ~/agent-gateway-quickstart && export PROJECT_ID=ajmalaziz-814-20250326021733 LOCATION=us-east1 GATEWAY_ID=demo-egress-gw \
  STAGING_BUCKET=gs://ajmalaziz-814-20250326021733-vertex-staging-us-east1 \
  MCP_URL=https://demo-weather-mcp-812402096883.us-east1.run.app/mcp
.venv/bin/python 2-deploy-agent.py deploy-adk            # ~10 min
AGENT_DISPLAY_NAME=gateway-demo-adk-agent .venv/bin/python 2-deploy-agent.py verify
PROJECT_NUMBER=812402096883 ORG_ID=485912938757 AGENT_DISPLAY_NAME=gateway-demo-adk-agent ./3-register-mcp.sh grant
.venv/bin/python 2-deploy-agent.py chat-adk "What's the weather in Melbourne?"
.venv/bin/python 2-deploy-agent.py chat-adk "Fetch https://api.github.com/zen"
./1-setup-gateway.sh logs 15m
```
Expected: verify shows `AGENT_IDENTITY` + gateway binding; first chat answers 22°C sunny; second reports an error (gateway is ENFORCED); logs show `demo-weather-mcp… ALLOWED` and `api.github.com DENIED`.

---

### Task 3: `4-register-gemini-enterprise.sh`

**Files:**
- Create: `4-register-gemini-enterprise.sh` (executable)
- Modify: `config.sh` (add `GE_APP_ID`, `GE_LOCATION`, `GE_PROJECT_NUMBER` defaults)

**Interfaces:**
- Consumes: `config.sh` vars, `AIP` from config, agent by display name (`AGENT_DISPLAY_NAME`, default `gateway-demo-adk-agent`).
- Produces: sub-commands `grant`, `register`, `publish`, `status`, `remove`.

- [x] **Step 1: config.sh additions**
```bash
# Gemini Enterprise (step 6). The app must already exist.
: "${GE_APP_ID:=your-gemini-enterprise-app-id}"   # engine id, e.g. my-app_1234567890
: "${GE_LOCATION:=global}"                        # global | us | eu
: "${GE_PROJECT_NUMBER:=${PROJECT_NUMBER}}"       # project that owns the app
export GE_APP_ID GE_LOCATION GE_PROJECT_NUMBER
```

- [x] **Step 2: the script**
```bash
#!/usr/bin/env bash
#
# Step 6 — register the ADK agent in a Gemini Enterprise app.
#
# Gemini Enterprise drives the agent through reasoningEngines:streamQuery, so
# the agent must be an ADK agent (2-deploy-agent.py deploy-adk). Registration
# is a Discovery Engine resource under the app's default assistant.
#
# Usage:
#   ./4-register-gemini-enterprise.sh grant     # IAM: GE service agent -> Vertex AI; agent -> MCP server
#   ./4-register-gemini-enterprise.sh register  # create or update the registration (PRIVATE)
#   ./4-register-gemini-enterprise.sh publish   # PRIVATE -> ENABLED for all app users
#   ./4-register-gemini-enterprise.sh status
#   ./4-register-gemini-enterprise.sh remove
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-gateway-demo-adk-agent}"
GE_DISPLAY_NAME="${GE_DISPLAY_NAME:-Gateway demo weather agent}"
GE_DESCRIPTION="${GE_DESCRIPTION:-Answers weather questions via an MCP server; every outbound call is governed by Agent Gateway.}"

if [ "${GE_LOCATION}" = "global" ]; then DE="https://discoveryengine.googleapis.com"; else DE="https://${GE_LOCATION}-discoveryengine.googleapis.com"; fi
PARENT="projects/${GE_PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}/assistants/default_assistant"
AGENTS_URL="${DE}/v1alpha/${PARENT}/agents"

_hdr() { echo -H "$(auth)" -H "x-goog-user-project: ${PROJECT_ID}" -H "Content-Type: application/json"; }

_agent_id() {
  curl -sS -H "$(auth)" "${AIP}/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines?pageSize=100" \
    | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('reasoningEngines',[]):
    if r.get('displayName')=='${AGENT_DISPLAY_NAME}': print(r['name'].split('/')[-1]); break"
}
_engine() { echo "projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines/$1"; }

# The GE registration that points at our reasoning engine, if any.
_ge_name() {
  curl -sS $(_hdr) "${AGENTS_URL}" | python3 -c "
import json,sys
want='$1'
for a in json.load(sys.stdin).get('agents',[]):
    if ((a.get('adkAgentDefinition') or {}).get('provisionedReasoningEngine') or {}).get('reasoningEngine','').endswith(want):
        print(a['name']); break"
}

grant() {
  # 6a. Gemini Enterprise's service agent must be allowed to invoke the reasoning engine.
  local ge_sa="serviceAccount:service-${GE_PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
  for role in roles/aiplatform.user roles/aiplatform.viewer; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${ge_sa}" --role="${role}" \
      --condition=None --quiet >/dev/null && echo "granted ${role} to ${ge_sa}"
  done
  # 6b. Least-privilege egress: this agent -> the MCP server (same as step 4, other agent).
  AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME}" ./3-register-mcp.sh grant
}

register() {
  local id; id="$(_agent_id)"
  [ -n "${id}" ] || { echo "agent '${AGENT_DISPLAY_NAME}' not found — run 2-deploy-agent.py deploy-adk first"; exit 1; }
  local body; body="$(python3 - "$(_engine "${id}")" <<'PY'
import json,sys,os
print(json.dumps({
  "displayName": os.environ["GE_DISPLAY_NAME"],
  "description": os.environ["GE_DESCRIPTION"],
  "icon": {"uri": "https://fonts.gstatic.com/s/i/short-term/release/googlesymbols/smart_toy/default/24px.svg"},
  "adkAgentDefinition": {
    "toolSettings": {"toolDescription": os.environ["GE_DESCRIPTION"]},
    "provisionedReasoningEngine": {"reasoningEngine": sys.argv[1]}}}))
PY
)"
  local existing; existing="$(_ge_name "reasoningEngines/${id}")"
  if [ -n "${existing}" ]; then
    echo "==> updating ${existing}"
    curl -sS -X PATCH $(_hdr) "${DE}/v1alpha/${existing}?updateMask=displayName,description,icon,adkAgentDefinition" -d "${body}"
  else
    echo "==> creating registration under ${PARENT}"
    curl -sS -X POST $(_hdr) "${AGENTS_URL}" -d "${body}"
  fi | python3 -c "import json,sys; a=json.load(sys.stdin); print(json.dumps({k:a.get(k) for k in ('name','displayName','state','error')}, indent=2))"
  echo "Registered as PRIVATE (visible to its creator). Run 'publish' to enable it for all users of the app."
}
export GE_DISPLAY_NAME GE_DESCRIPTION

publish() {
  local id; id="$(_agent_id)"; local name; name="$(_ge_name "reasoningEngines/${id}")"
  [ -n "${name}" ] || { echo "not registered yet — run register first"; exit 1; }
  curl -sS -X PATCH $(_hdr) "${DE}/v1alpha/${name}?updateMask=sharingConfig" \
    -d '{"sharingConfig":{"scope":"ALL_USERS"}}' | python3 -c "import json,sys; a=json.load(sys.stdin); print(a.get('name'), a.get('state'), a.get('error',''))"
}

status() {
  curl -sS $(_hdr) "${AGENTS_URL}" | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('agents',[]):
    re=((a.get('adkAgentDefinition') or {}).get('provisionedReasoningEngine') or {}).get('reasoningEngine','')
    print('%-40s %-9s %s' % (a.get('displayName'), a.get('state'), re.split('/')[-1] if re else '(not ADK)'))"
}

remove() {
  local id; id="$(_agent_id)"; local name; name="$(_ge_name "reasoningEngines/${id}")"
  [ -n "${name}" ] || { echo "nothing registered for ${AGENT_DISPLAY_NAME}"; exit 0; }
  curl -sS -X DELETE $(_hdr) "${DE}/v1alpha/${name}" | head -c 300; echo; echo "removed ${name}"
}

"${@:-status}"
```

- [x] **Step 3: live test**
```bash
cd ~/agent-gateway-quickstart && export PROJECT_ID=ajmalaziz-814-20250326021733 PROJECT_NUMBER=812402096883 ORG_ID=485912938757 LOCATION=us-east1 GE_APP_ID=demo_1753333559301
./4-register-gemini-enterprise.sh grant && ./4-register-gemini-enterprise.sh register && ./4-register-gemini-enterprise.sh status
# drive the agent the way the GE UI does:
curl -sS -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: $PROJECT_ID" -H "Content-Type: application/json" \
  "https://discoveryengine.googleapis.com/v1alpha/projects/812402096883/locations/global/collections/default_collection/engines/demo_1753333559301/assistants/default_assistant:streamAssist" \
  -d '{"query":{"text":"What is the weather in Melbourne?"},"agentsConfig":{"agent":"<GE agent name from status>"}}' | head -c 2000
./4-register-gemini-enterprise.sh publish; ./4-register-gemini-enterprise.sh status
```
Expected: registration shows `PRIVATE` then `ENABLED`; the assist reply contains the canned weather; gateway logs show ALLOWED for the MCP host. If `toolSettings` is rejected with 400, drop it from the payload (the v1alpha schema no longer lists it).

---

### Task 4: `terraform/` root module

**Files:**
- Create: `terraform/versions.tf`, `variables.tf`, `apis.tf`, `gateway.tf`, `authz.tf`, `registry.tf`, `mcp-server.tf`, `agent.tf`, `gemini-enterprise.tf`, `outputs.tf`, `terraform.tfvars.example`, `scripts/tar_b64.sh`, `scripts/ge_agent.sh`, `README.md`, `.gitignore` additions (`terraform/.terraform/`, `*.tfstate*`, `terraform/*.tfvars`).

**Interfaces:**
- Consumes: `../agent/` (Task 1), `../mcp-server/`, `../agent/class_methods.json`.
- Produces: outputs `gateway`, `mcp_url`, `agent_resource_name`, `agent_principal`, `gemini_enterprise_agent`.

- [x] **Step 1: write the files** (full HCL is in the implementation; key resource shapes)

`authz.tf`:
```hcl
resource "google_network_services_authz_extension" "iap" {
  name      = "${var.gateway_id}-iap-authzextension"
  location  = var.location
  service   = "iap.googleapis.com"
  timeout   = "10s"
  fail_open = var.enforcement_mode == "DRY_RUN"
  metadata  = { iamEnforcementMode = var.enforcement_mode, iapPolicyVersion = "V1" }
  depends_on = [google_project_service.apis]
}
resource "google_network_security_authz_policy" "iap" {
  name     = "${var.gateway_id}-iap-authzpolicy"
  location = var.location
  action   = "CUSTOM"
  target { resources = ["projects/${local.project_number}/locations/${var.location}/agentGateways/${google_network_services_agent_gateway.egress.name}"] }
  custom_provider { authz_extension { resources = [google_network_services_authz_extension.iap.id] } }
}
```
(`policy_profile = "REQUEST_AUTHZ"` and `target.load_balancing_scheme` added if the provider schema requires them — check `terraform validate`.)

`agent.tf`:
```hcl
data "external" "agent_source" {
  program = ["bash", "${path.module}/scripts/tar_b64.sh", "${path.module}/..", "agent"]
}
resource "google_vertex_ai_reasoning_engine" "adk" {
  count        = var.deploy_agent ? 1 : 0
  display_name = var.agent_display_name
  region       = var.location
  spec {
    agent_framework = "google-adk"
    class_methods   = file("${path.module}/../agent/class_methods.json")
    identity_type   = "AGENT_IDENTITY"
    source_code_spec {
      inline_source { source_archive = data.external.agent_source.result.b64 }
      python_spec { entrypoint_module = "agent.agent"  entrypoint_object = "root_agent"
                    requirements_file = "agent/requirements.txt"  version = "3.12" }
    }
    deployment_spec {
      env { name = "MCP_URL" value = local.mcp_url }
      env { name = "MODEL"   value = var.agent_model }
      env { name = "AGENT_SOURCE_SHA" value = data.external.agent_source.result.sha }  # forces redeploy on code change
      agent_gateway_config { agent_to_anywhere_config { agent_gateway = google_network_services_agent_gateway.egress.id } }
    }
  }
  depends_on = [google_agent_registry_service.baseline, google_iap_agent_registry_iam_member.all_agents, google_agent_registry_service.mcp]
  timeouts { create = "45m" update = "45m" delete = "30m" }
}
resource "google_project_iam_member" "agent_vertex" {
  count = var.deploy_agent ? 1 : 0
  project = var.project_id  role = "roles/aiplatform.user"
  member  = "principal://${google_vertex_ai_reasoning_engine.adk[0].spec[0].effective_identity}"
}
resource "google_iap_agent_registry_mcp_server_iam_member" "agent_to_mcp" {
  count = var.deploy_agent ? 1 : 0
  project = var.project_id  location = var.location
  mcp_server_id = element(split("/", google_agent_registry_service.mcp.registry_resource), length(split("/", google_agent_registry_service.mcp.registry_resource)) - 1)
  role   = "roles/iap.egressor"
  member = "principal://${google_vertex_ai_reasoning_engine.adk[0].spec[0].effective_identity}"
}
```

`scripts/tar_b64.sh` (external data source contract: JSON in → JSON out):
```bash
#!/usr/bin/env bash
set -euo pipefail
root="$1"; dir="$2"
tmp="$(mktemp)"; tar -C "$root" --exclude='__pycache__' --exclude='*.pyc' -czf "$tmp" "$dir"
sha="$(sha256sum "$tmp" | cut -c1-16)"
printf '{"b64":"%s","sha":"%s"}' "$(base64 -w0 "$tmp")" "$sha"; rm -f "$tmp"
```

`scripts/ge_agent.sh` (`upsert`|`delete`, reads env `DE_ENDPOINT PARENT PROJECT_ID REASONING_ENGINE DISPLAY_NAME DESCRIPTION SCOPE`): same logic as Task 3's `register`/`publish`/`remove` in one file, used by:
```hcl
resource "terraform_data" "ge_agent" {
  count = var.gemini_enterprise_app_id != "" && var.deploy_agent ? 1 : 0
  input = { endpoint = local.ge_endpoint, parent = local.ge_parent, project_id = var.project_id,
            reasoning_engine = google_vertex_ai_reasoning_engine.adk[0].id,
            display_name = var.gemini_enterprise_display_name, description = var.gemini_enterprise_description,
            scope = var.publish_to_all_users ? "ALL_USERS" : "RESTRICTED" }
  provisioner "local-exec" { command = "${path.module}/scripts/ge_agent.sh upsert"  environment = {...self.input...} }
  provisioner "local-exec" { when = destroy  command = "${path.module}/scripts/ge_agent.sh delete" environment = {...self.input...} }
  depends_on = [google_project_iam_member.ge_service_agent]
}
```

- [x] **Step 2: `terraform init && terraform validate && terraform fmt -check`** — Expected: success.

- [x] **Step 3: live apply (us-central1)**
```bash
cd ~/agent-gateway-quickstart/terraform && cat > test.auto.tfvars <<'T'
project_id = "ajmalaziz-814-20250326021733"
location   = "us-central1"
gateway_id = "tf-demo-egress-gw"
mcp_service_name = "tf-demo-weather-mcp"
agent_display_name = "tf-gateway-demo-adk-agent"
gemini_enterprise_app_id = "demo_1753333559301"
gemini_enterprise_display_name = "TF gateway demo weather agent"
T
terraform apply -auto-approve      # gateway ~3 min, build ~2 min, agent ~10-15 min
```
Then functional checks with outputs: `:streamQuery` weather question → 22°C; fetch github → error (if `enforcement_mode=ENFORCED`) or success + DENIED log; GE status shows the registration.

- [x] **Step 4: `terraform destroy -auto-approve`**, then confirm nothing remains: `gcloud beta network-services agent-gateways list --location=us-central1`, registry services list (us-central1) empty, reasoning engine gone, GE agents list without TF entry, Cloud Run service gone. Remove `test.auto.tfvars`.

---

### Task 5: README updates

**Files:**
- Modify: `README.md` (Files table, Prerequisites, new Step 6, new Terraform section, Cleanup, Gotchas)
- Create: `terraform/README.md`

- [x] Add rows for `agent/`, `4-register-gemini-enterprise.sh`, `terraform/`; Step 6 (deploy-adk → grant → register → publish → try in GE UI → logs); Terraform section (what it creates, `terraform.tfvars.example`, apply/destroy, what is local-exec and why); Cleanup additions (`teardown-adk`, `4-… remove`); Gotchas: ADK agent identity needs `roles/aiplatform.user`; `google-adk[mcp]` extra; registrations start PRIVATE; class_methods must be declared for source deploys.

---

### Task 6: branch, commit, PR

- [x] `git checkout -b feat/gemini-enterprise-terraform`; `git add -A` (verify `.venv`, `.terraform`, tfstate, tfvars are ignored); one commit per task where sensible; `git push -u origin feat/gemini-enterprise-terraform`; `gh pr create --title "Gemini Enterprise registration + Terraform implementation" --body <summary + what was validated live>`.
