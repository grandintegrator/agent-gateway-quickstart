"""Step 3 — deploy a minimal agent with Agent Identity, bound to the gateway.

The agent is deliberately trivial: it makes one outbound HTTPS call — either an
MCP tools/call or a plain GET — to whatever URL you hand it. No LLM, no tools
framework. That is the point: everything you observe (ALLOWED vs DENIED) comes
from the gateway, not from the agent.

Two config entries make this whole demo work, both set at CREATE time so it is
a single deploy (each later PATCH is a ~13-minute container redeploy):

    "agent_gateway_config": {...}          # bind the agent to the gateway
    "identity_type": "AGENT_IDENTITY"      # mandatory for any gateway binding

AGENT_IDENTITY gives the agent a SPIFFE-style principal — that principal is
what the gateway authorizes. A plain service account has no such principal,
so a gateway binding without AGENT_IDENTITY is rejected outright. Do NOT also
set "service_account".

Usage:
    pip install "google-cloud-aiplatform[agent_engines]"

    python 2-deploy-agent.py deploy     # ~8 min
    python 2-deploy-agent.py demo       # call the MCP server (allowed) + an unregistered URL
    python 2-deploy-agent.py verify     # identity + gateway binding on the live agent
    python 2-deploy-agent.py teardown

Configuration comes from the environment (same variables as config.sh), plus:
    MCP_URL   the dummy MCP server endpoint, e.g. https://<cloud-run-url>/mcp
"""

import json
import os
import subprocess
import sys
import urllib.request

PROJECT_ID = os.environ.get("PROJECT_ID", "your-project-id")
LOCATION = os.environ.get("LOCATION", "us-central1")
GATEWAY_ID = os.environ.get("GATEWAY_ID", "demo-egress-gw")
STAGING_BUCKET = os.environ.get("STAGING_BUCKET", f"gs://{PROJECT_ID}-agent-staging")
MCP_URL = os.environ.get("MCP_URL", "https://your-mcp-server.example.com/mcp")

DISPLAY_NAME = "gateway-demo-agent"
DENIED_URL = "https://api.github.com/zen"  # deliberately NOT registered


# ==============================================================================
# The agent. This is the whole thing.
# ==============================================================================
class GatewayDemoAgent:
    """Calls one URL. Whether the call succeeds is entirely the gateway's decision."""

    def set_up(self):
        pass

    def query(self, url: str, tool: str = "", arguments: dict | None = None) -> dict:
        import json
        import urllib.request

        if tool:  # MCP tools/call, as a bare JSON-RPC POST
            body = json.dumps({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": tool, "arguments": arguments or {}},
            }).encode()
            req = urllib.request.Request(url, data=body, headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
            })
        else:  # plain GET
            req = urllib.request.Request(url)

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                text = resp.read().decode()
                # streamable-HTTP MCP servers may frame the reply as SSE
                if text.lstrip().startswith(("event:", "data:")):
                    text = "".join(l[5:].strip() for l in text.splitlines()
                                   if l.startswith("data:"))
                return {"url": url, "reached": True, "status": resp.status,
                        "response": text[:800]}
        except Exception as exc:
            return {"url": url, "reached": False,
                    "error": f"{type(exc).__name__}: {exc}"[:400]}


# ==============================================================================
# Deploy — gateway + identity set at CREATE time, so this is ONE deploy.
# ==============================================================================
def deploy():
    # agent_gateway_config and identity_type are exposed by the NEW SDK client
    # (agentplatform.Client). The legacy vertexai.agent_engines.create() path
    # does not accept them.
    import agentplatform

    client = agentplatform.Client(project=PROJECT_ID, location=LOCATION)
    remote = client.agent_engines.create(
        agent=GatewayDemoAgent(),
        config={
            "display_name": DISPLAY_NAME,
            "staging_bucket": STAGING_BUCKET,
            # `requirements` REPLACES the serving image's dependency set, it
            # does not add to it. Omitting google-cloud-aiplatform, or listing
            # it without the opentelemetry pair, kills the container at boot.
            "requirements": [
                "google-cloud-aiplatform[agent_engines]",
                "opentelemetry-api",
                "opentelemetry-sdk",
            ],
            # ---- the only two entries that matter ------------------------
            "agent_gateway_config": {
                "agent_to_anywhere_config": {
                    "agent_gateway": (
                        f"projects/{PROJECT_ID}/locations/{LOCATION}"
                        f"/agentGateways/{GATEWAY_ID}"
                    )
                }
            },
            "identity_type": "AGENT_IDENTITY",
            # --------------------------------------------------------------
        },
    )
    print("\nDEPLOYED:", remote.api_resource.name)
    print("\nNext: ./3-register-mcp.sh grant   (least-privilege grant for this agent)")


# ==============================================================================
# Plumbing: plain REST against the reasoningEngines API.
# ==============================================================================
API = f"https://{LOCATION}-aiplatform.googleapis.com/v1beta1"
BASE = f"{API}/projects/{PROJECT_ID}/locations/{LOCATION}/reasoningEngines"


def _token() -> str:
    return subprocess.check_output(
        ["gcloud", "auth", "print-access-token"], text=True).strip()


def _rest(url: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {_token()}",
                 "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.load(resp)


def _agent_id() -> str:
    data = _rest(f"{BASE}?pageSize=100")
    for r in data.get("reasoningEngines", []):
        if r.get("displayName") == DISPLAY_NAME:
            return r["name"].split("/")[-1]
    sys.exit(f"no agent named {DISPLAY_NAME}; run `deploy` first")


def _invoke(agent_id: str, payload: dict) -> dict:
    return _rest(f"{BASE}/{agent_id}:query",
                 {"class_method": "query", "input": payload})


# ==============================================================================
# Demo — one MCP tool call that is allowed, one destination that is not.
# ==============================================================================
def demo():
    agent_id = _agent_id()

    print(f"\n=== agent -> MCP server (registered + granted => ALLOWED) ===\n{MCP_URL}")
    out = _invoke(agent_id, {"url": MCP_URL, "tool": "get_weather",
                             "arguments": {"city": "Melbourne"}})
    print(json.dumps(out.get("output", out), indent=2)[:900])

    print(f"\n=== agent -> unregistered API (DENIED once enforced) ===\n{DENIED_URL}")
    out = _invoke(agent_id, {"url": DENIED_URL})
    print(json.dumps(out.get("output", out), indent=2)[:900])

    print("\nNow read the gateway's verdicts:  ./1-setup-gateway.sh logs 15m")
    print("(in DRY_RUN both calls succeed, but the denial is already logged)")


# verify — a null agentGatewayConfig means the binding did not take.
def verify():
    r = _rest(f"{BASE}/{_agent_id()}")
    s = r["spec"]
    print("agent             :", r.get("displayName"))
    print("created           :", r.get("createTime"))
    print("identityType      :", s.get("identityType"))
    print("effectiveIdentity :", s.get("effectiveIdentity"))
    print("agentGatewayConfig:", json.dumps(
        (s.get("deploymentSpec") or {}).get("agentGatewayConfig"), indent=2))


def teardown():
    import agentplatform
    client = agentplatform.Client(project=PROJECT_ID, location=LOCATION)
    client.agent_engines.delete(
        name=f"projects/{PROJECT_ID}/locations/{LOCATION}/reasoningEngines/{_agent_id()}",
        force=True)
    print("deleted", DISPLAY_NAME)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "verify"
    {"deploy": deploy, "demo": demo, "verify": verify, "teardown": teardown}[cmd]()
