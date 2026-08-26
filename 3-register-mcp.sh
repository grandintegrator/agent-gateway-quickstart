#!/usr/bin/env bash
#
# Step 4 — allow the agent to reach the MCP server. Two independent gates:
#
#   register : put the MCP server on the gateway's allowlist (Agent Registry)
#   grant    : give ONE agent's identity roles/iap.egressor on ONE MCP server
#
# A destination is reachable only when BOTH are in place.
#
# MCP servers are registered WITH their tool list (tools.json). MCP is the one
# protocol whose request bodies the gateway parses, so a registered tool list
# is what enables per-TOOL authorization — every other protocol is per-host,
# all-or-nothing.
#
# Usage:
#   ./3-register-mcp.sh register https://<cloud-run-url>/mcp
#   ./3-register-mcp.sh grant        # after the agent is deployed (step 3)
#   ./3-register-mcp.sh status
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

MCP_NAME="${MCP_NAME:-demo-weather-mcp}"
AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-gateway-demo-agent}"

register() {
  local url="${1:?usage: $0 register <mcp-endpoint-url>}"
  gcloud alpha agent-registry services create "${MCP_NAME}" \
    --project="${PROJECT_ID}" --location="${LOCATION}" \
    --display-name="${MCP_NAME}" \
    --mcp-server-spec-type=tool-spec \
    --mcp-server-spec-content="$(cat mcp-server/tools.json)" \
    --interfaces="[{url=\"${url}\",protocolBinding=\"jsonrpc\"}]" \
    --format="value(registryResource)"
  echo "Registered. Propagation to the gateway takes ~4 minutes."
}

# Look up the registry's mcpServers projection for our entry.
_mcp_id() {
  curl -sS -H "$(auth)" \
    "https://agentregistry.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/mcpServers" \
    | python3 -c "
import json,sys
for x in json.load(sys.stdin).get('mcpServers',[]):
    if x.get('displayName')=='${MCP_NAME}':
        print(x['name'].split('/')[-1]); break"
}

# Look up the deployed agent's numeric id by display name.
_agent_id() {
  curl -sS -H "$(auth)" \
    "${AIP}/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines?pageSize=100" \
    | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('reasoningEngines',[]):
    if r.get('displayName')=='${AGENT_DISPLAY_NAME}':
        print(r['name'].split('/')[-1]); break"
}

grant() {
  local mcp_id agent_id
  mcp_id="$(_mcp_id)"
  [ -n "${mcp_id}" ] || { echo "MCP server '${MCP_NAME}' not in the registry yet — run register first"; exit 1; }
  agent_id="$(_agent_id)"
  [ -n "${agent_id}" ] || { echo "agent '${AGENT_DISPLAY_NAME}' not found — run 2-deploy-agent.py deploy first"; exit 1; }

  # The agent's SPIFFE-style Agent Identity principal — this exact one agent.
  local principal="principal://${TRUST_DOMAIN}/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${LOCATION}/reasoningEngines/${agent_id}"

  local f; f="$(mktemp)"
  cat > "$f" <<EOF
{"bindings":[{"role":"roles/iap.egressor","members":["${principal}"]}]}
EOF
  gcloud beta iap web set-iam-policy "$f" --project="${PROJECT_ID}" \
    --mcp-server="${mcp_id}" --region="${LOCATION}" --quiet
  rm -f "$f"

  echo "granted roles/iap.egressor on ${MCP_NAME} (${mcp_id})"
  echo "     to ${principal}"
}

status() {
  local mcp_id; mcp_id="$(_mcp_id)"
  [ -n "${mcp_id}" ] || { echo "MCP server '${MCP_NAME}' not registered"; exit 1; }
  echo "--- registry entry: ${mcp_id}"
  echo "--- IAM policy on the MCP server:"
  gcloud beta iap web get-iam-policy --project="${PROJECT_ID}" \
    --mcp-server="${mcp_id}" --region="${LOCATION}"
}

remove() {
  gcloud alpha agent-registry services delete "${MCP_NAME}" \
    --project="${PROJECT_ID}" --location="${LOCATION}" --quiet
}

"${@:-status}"
