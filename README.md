# Agent Gateway quickstart

A minimal, end-to-end example of governing agent egress on Vertex AI Agent
Engine with **Agent Gateway** and **Agent Identity**:

1. create an `AGENT_TO_ANYWHERE` gateway with IAP enforcement,
2. deploy a dummy MCP server (canned weather data) to Cloud Run,
3. deploy a tiny agent that runs with `AGENT_IDENTITY` and is bound to the
   gateway,
4. register the MCP server and grant the agent least-privilege access to it,
5. watch the gateway log an **ALLOWED** verdict for the MCP call and a
   **DENIED** verdict for an unregistered API.

```
   ┌──────────────────────┐        ┌────────────────────────┐
   │  gateway-demo-agent  │        │  AGENT_TO_ANYWHERE     │──▶ demo MCP server   ALLOWED
   │  (AGENT_IDENTITY)    │───────▶│  gateway + IAP policy  │──▶ api.github.com    DENIED
   └──────────────────────┘        └────────────────────────┘
```

## How it works

Agent Gateway is a managed proxy in the network path of a deployed agent. It
terminates and re-signs TLS, so it sees the hostname — and, for MCP only, the
request body — of every outbound connection, and allows or denies each one.

It is **default deny**, with two independent gates. A destination is reachable
only when **both** hold:

| Gate | Resource | Command |
|------|----------|---------|
| Registered | Agent Registry `services` entry | `gcloud alpha agent-registry services create` |
| Granted | `roles/iap.egressor` for the agent's identity | `gcloud beta iap web set-iam-policy` |

Registration alone allows nothing; a grant alone allows nothing.

The agent itself must run with `identity_type: AGENT_IDENTITY`, which gives it
a SPIFFE-style principal — that principal is what the gateway authorizes:

```
principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/projects/PROJECT_NUMBER/locations/LOCATION/reasoningEngines/AGENT_ID
```

## Files

| File | What it does |
|------|--------------|
| `config.sh` | Project / region / gateway settings shared by the shell scripts |
| `1-setup-gateway.sh` | Gateway + IAP enforcement (DRY_RUN) + baseline allowlist + broad grant |
| `mcp-server/` | The dummy MCP server (two tools, canned data) for Cloud Run |
| `2-deploy-agent.py` | Deploys the demo agent with `AGENT_IDENTITY`, bound to the gateway |
| `3-register-mcp.sh` | Registers the MCP server (with its tool list) and grants one agent access |

## Prerequisites

- A project with these APIs enabled: `aiplatform`, `networkservices`,
  `networksecurity`, `iap`, `agentregistry`, `run`.
- `gcloud` authenticated with permissions on all of the above.
- Python 3.10+ with `pip install "google-cloud-aiplatform[agent_engines]"`.
- A GCS staging bucket for Agent Engine deploys.

## Step 0 — configure

Edit `config.sh` (or export the variables): `PROJECT_ID`, `PROJECT_NUMBER`,
`ORG_ID`, `LOCATION`. The gateway, registry, and agent must all live in the
**same region**.

## Step 1 — gateway, enforcement hook, baseline allowlist

```bash
./1-setup-gateway.sh all
```

This creates four things:

- the **gateway** (`networkservices.googleapis.com/agentGateways`, ~2 min),
- an **IAP authz extension + policy** — a gateway without these enforces
  *nothing*. It starts in `DRY_RUN`/`failOpen`, meaning denials are logged but
  traffic still flows,
- the **baseline allowlist** — the gateway fronts *everything*, including the
  agent's own calls to Vertex AI, Cloud Trace, and Cloud Logging. Skip this
  and an agent bound to the gateway fails to deploy (~13 min later, with the
  unhelpful message `The Reasoning Engine failed to be updated`),
- a **broad grant**: every agent in the project may reach every registered
  destination. Step 4 shows the least-privilege alternative.

## Step 2 — deploy the dummy MCP server

```bash
gcloud run deploy demo-weather-mcp --source mcp-server \
  --project $PROJECT_ID --region $LOCATION --allow-unauthenticated
```

If an org policy (domain-restricted sharing) rejects the `allUsers` binding,
disable the invoker IAM check instead:

```bash
gcloud beta run services update demo-weather-mcp \
  --project $PROJECT_ID --region $LOCATION --no-invoker-iam-check
```

Sanity-check it (the MCP endpoint is at `/mcp`):

```bash
curl -sS -X POST "$(gcloud run services describe demo-weather-mcp \
    --project $PROJECT_ID --region $LOCATION --format='value(status.url)')/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_weather","arguments":{"city":"Melbourne"}}}'
```

## Step 3 — deploy the agent, with Agent Identity, bound to the gateway

```bash
source config.sh
export STAGING_BUCKET=gs://your-staging-bucket
python 2-deploy-agent.py deploy      # ~8 min
python 2-deploy-agent.py verify      # identityType + gateway binding
```

Both `agent_gateway_config` and `identity_type: AGENT_IDENTITY` are set at
**create time** — one deploy. On an existing agent each would be a separate
PATCH and a ~13-minute redeploy, and the identity PATCH must come first: a
gateway binding without `AGENT_IDENTITY` is rejected.

## Step 4 — register the MCP server, grant the agent

```bash
./3-register-mcp.sh register https://<cloud-run-url>/mcp
./3-register-mcp.sh grant
./3-register-mcp.sh status
```

The registration includes `mcp-server/tools.json`. Because the gateway parses
MCP request bodies, a registered tool list enables **per-tool** authorization —
`roles/iap.egressor` can even carry an IAM condition on the tool name, so one
agent may call `get_weather` while another may also call `get_forecast`. All
other protocols are governed per-host.

Registry changes take **~4 minutes** to propagate to the gateway — don't
diagnose an `(UNREGISTERED)` verdict before then.

## Step 5 — run the demo, read the verdicts

```bash
python 2-deploy-agent.py demo
./1-setup-gateway.sh logs 15m
```

Expected output, one line per destination:

```
HOSTNAME                                       VERDICT   REGISTRY MATCH
demo-weather-mcp-xxxx.run.app                  ALLOWED   agentregistry-...
api.github.com                                 DENIED    (UNREGISTERED)
us-central1-aiplatform.mtls.googleapis.com     ALLOWED   agentregistry-...
```

In `DRY_RUN` both agent calls succeed but the denial is already logged. When
the log shows nothing unexpected:

```bash
./1-setup-gateway.sh enforce     # DRY_RUN -> ENFORCED: DENIED now means blocked
```

## Cleanup

```bash
python 2-deploy-agent.py teardown              # the agent (unbind first is implicit in delete)
./3-register-mcp.sh remove                     # the registry entry
gcloud run services delete demo-weather-mcp --project $PROJECT_ID --region $LOCATION
./1-setup-gateway.sh teardown                  # policy -> extension -> gateway
```

## Gotchas worth knowing before you start

- **Register the `.mtls.` variants of Google APIs.** Matching is by exact
  hostname and Google client libraries mostly egress via
  `*.mtls.googleapis.com`. `1-setup-gateway.sh register_baseline` covers both
  forms — including `iamcredentials.googleapis.com`, which Agent Identity
  token exchange calls at runtime.
- **The gateway's `registries` field must point at the regional registry**
  for Agent Runtime agents. Point it at the global registry and every
  destination reads as unregistered.
- **IAM policy files are bare.** `gcloud beta iap web set-iam-policy` wants
  `{"bindings": [...]}`, not `{"policy": {...}}`.
- **Agents created before 2026-04-29 cannot bind to a gateway.** Check
  `createTime` first.
- **Test `AGENT_IDENTITY` on its own before binding a real agent.** With some
  `google-adk`/`google-genai` version combinations, an LLM agent on
  `AGENT_IDENTITY` answers its first call and returns empty responses after
  that. Switch the identity first, invoke the agent several times in a row
  (one call proves nothing), and only then attach the gateway. The trivial
  agent in this repo has no LLM and is not affected.
- **Bring-your-own-container images must trust the gateway's CA.** The
  gateway re-signs TLS; source-based deploys get the root injected
  automatically, custom images must bake it in (it's published on the gateway
  resource under `agentGatewayCard.rootCertificates`).
