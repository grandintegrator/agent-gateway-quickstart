#!/usr/bin/env bash
#
# Step 1 — create the Agent Gateway and everything it needs to enforce policy.
#
# Agent Gateway is a managed proxy in the network path of a deployed agent:
#
#   your agent ──▶ [ AGENT_TO_ANYWHERE gateway ] ──▶ MCP servers, A2A agents, APIs
#
# It is DEFAULT DENY. Traffic flows only when the destination is BOTH
# registered in Agent Registry AND covered by a roles/iap.egressor grant for
# the agent's identity. Registration alone allows nothing; a grant alone
# allows nothing.
#
# Usage:
#   ./1-setup-gateway.sh all           # create_gateway + create_authz + register_baseline + grant_all
#   ./1-setup-gateway.sh <subcommand>  # any individual step below
#   ./1-setup-gateway.sh gateways|registry|logs   # inspect
#   ./1-setup-gateway.sh enforce       # flip DRY_RUN -> ENFORCED
#   ./1-setup-gateway.sh teardown
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

# ------------------------------------------------------------------------------
# 1a. The gateway itself (networkservices.googleapis.com)
#
# NOTE: `registries` must be the REGIONAL registry for Agent Runtime agents.
# Pointing it at the global registry means the gateway cannot see your
# allowlist and every call is denied.
# ------------------------------------------------------------------------------
create_gateway() {
  echo "==> creating AGENT_TO_ANYWHERE gateway ${GATEWAY_ID}"
  curl -sS -X POST -H "$(auth)" -H "Content-Type: application/json" \
    "${NS}/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways?agentGatewayId=${GATEWAY_ID}" \
    -d '{
      "description": "Governs agent -> MCP server / A2A / API egress",
      "googleManaged": { "governedAccessPath": "AGENT_TO_ANYWHERE" },
      "registries": ["//agentregistry.googleapis.com/projects/'"${PROJECT_ID}"'/locations/'"${LOCATION}"'"]
    }' | python3 -m json.tool
  echo "    (long-running operation, ~2 min)"
}

wait_gateway() {
  echo -n "==> waiting for gateway ${GATEWAY_ID} "
  until curl -sfS -H "$(auth)" \
      "${NS}/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${GATEWAY_ID}" \
      -o /dev/null 2>/dev/null; do
    echo -n "."; sleep 15
  done
  echo " ready"
}

gateways() {
  curl -sS -H "$(auth)" "${NS}/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways" \
    | python3 -c "
import json,sys
for g in json.load(sys.stdin).get('agentGateways',[]):
    print('%-22s %-18s registries=%s' % (
        g['name'].split('/')[-1],
        (g.get('googleManaged') or {}).get('governedAccessPath','SELF_MANAGED'),
        g.get('registries')))"
}

# ------------------------------------------------------------------------------
# 1b. The IAP enforcement hook. A gateway with no authz policy enforces NOTHING.
#
# Start in DRY_RUN with failOpen: true — denials are logged but traffic still
# flows, so you can discover your real dependency list before anything breaks.
# Flip to ENFORCED (below) only once the logs are clean.
# ------------------------------------------------------------------------------
create_authz() {
  local tmp; tmp="$(mktemp -d)"

  cat > "${tmp}/ext.yaml" <<EOF
name: ${GATEWAY_ID}-iap-authzextension
service: iap.googleapis.com
failOpen: true
timeout: 10s
metadata:
  iamEnforcementMode: "DRY_RUN"
  iapPolicyVersion: "V1"
EOF
  gcloud beta service-extensions authz-extensions import "${GATEWAY_ID}-iap-authzextension" \
    --source="${tmp}/ext.yaml" --location="${LOCATION}" --project="${PROJECT_ID}" --quiet

  cat > "${tmp}/policy.yaml" <<EOF
name: ${GATEWAY_ID}-iap-authzpolicy
target:
  resources:
  - projects/${PROJECT_NUMBER}/locations/${LOCATION}/agentGateways/${GATEWAY_ID}
action: CUSTOM
policyProfile: REQUEST_AUTHZ
customProvider:
  authzExtension:
    resources:
    - projects/${PROJECT_NUMBER}/locations/${LOCATION}/authzExtensions/${GATEWAY_ID}-iap-authzextension
EOF
  gcloud beta network-security authz-policies import "${GATEWAY_ID}-iap-authzpolicy" \
    --source="${tmp}/policy.yaml" --location="${LOCATION}" --project="${PROJECT_ID}" --quiet
  rm -rf "${tmp}"
}

# Flip DRY_RUN -> ENFORCED once the dry-run logs show no unexpected denials.
enforce() {
  local tmp; tmp="$(mktemp -d)"
  cat > "${tmp}/ext.yaml" <<EOF
name: ${GATEWAY_ID}-iap-authzextension
service: iap.googleapis.com
failOpen: false
timeout: 10s
metadata:
  iamEnforcementMode: "ENFORCED"
  iapPolicyVersion: "V1"
EOF
  gcloud beta service-extensions authz-extensions import "${GATEWAY_ID}-iap-authzextension" \
    --source="${tmp}/ext.yaml" --location="${LOCATION}" --project="${PROJECT_ID}" --quiet
  rm -rf "${tmp}"
  echo "authz extension -> ENFORCED (failOpen=false)"
}

dryrun() {
  local tmp; tmp="$(mktemp -d)"
  cat > "${tmp}/ext.yaml" <<EOF
name: ${GATEWAY_ID}-iap-authzextension
service: iap.googleapis.com
failOpen: true
timeout: 10s
metadata:
  iamEnforcementMode: "DRY_RUN"
  iapPolicyVersion: "V1"
EOF
  gcloud beta service-extensions authz-extensions import "${GATEWAY_ID}-iap-authzextension" \
    --source="${tmp}/ext.yaml" --location="${LOCATION}" --project="${PROJECT_ID}" --quiet
  rm -rf "${tmp}"
  echo "authz extension -> DRY_RUN (failOpen=true)"
}

# ------------------------------------------------------------------------------
# 1c. The allowlist — Agent Registry.
#
# THE STEP EVERYONE MISSES: the gateway sits in front of EVERYTHING, including
# the agent's own calls to Vertex AI, Cloud Trace and Cloud Logging. If those
# are not allowlisted, the agent cannot reach its own LLM — and deploying an
# agent bound to the gateway fails after ~13 minutes with only:
#     "The Reasoning Engine failed to be updated."
#
# Also: matching is by EXACT hostname, and Google client libraries mostly
# egress over the *.mtls.googleapis.com variants. Register both forms.
# ------------------------------------------------------------------------------
register_baseline() {
  _svc allow-aiplatform        "Vertex AI ${LOCATION}" "https://${LOCATION}-aiplatform.googleapis.com"
  _svc allow-aiplatform-mtls   "Vertex AI mTLS"        "https://${LOCATION}-aiplatform.mtls.googleapis.com"
  _svc allow-aiplatform-rep    "Vertex AI rep"         "https://aiplatform.${LOCATION}.rep.googleapis.com"
  _svc allow-aiplatform-global "Vertex AI global mTLS" "https://aiplatform.mtls.googleapis.com"
  _svc allow-telemetry         "Cloud Trace"           "https://telemetry.googleapis.com"
  _svc allow-telemetry-mtls    "Cloud Trace mTLS"      "https://telemetry.mtls.googleapis.com"
  _svc allow-logging           "Cloud Logging"         "https://logging.googleapis.com"
  _svc allow-logging-mtls      "Cloud Logging mTLS"    "https://logging.mtls.googleapis.com"
  _svc allow-crm               "ResourceManager"       "https://cloudresourcemanager.googleapis.com"
  _svc allow-crm-mtls          "ResourceManager mTLS"  "https://cloudresourcemanager.mtls.googleapis.com"
  # gRPC clients present host:443 and matching is exact — the ADK runtime's
  # telemetry setup calls Resource Manager over gRPC at boot.
  _svc allow-crm-mtls-grpc     "ResourceManager mTLS gRPC" "https://cloudresourcemanager.mtls.googleapis.com:443"
  _svc allow-iamcreds          "IAM Credentials"       "https://iamcredentials.googleapis.com"
  _svc allow-iamcreds-mtls     "IAM Credentials mTLS"  "https://iamcredentials.mtls.googleapis.com"
  echo "(registrations take ~4 min to propagate to the gateway)"
}

_svc() {
  printf '%-26s ' "$1"
  local out
  if out="$(gcloud alpha agent-registry services create "$1" \
      --project="${PROJECT_ID}" --location="${LOCATION}" \
      --display-name="$2" --endpoint-spec-type=no-spec \
      --interfaces="[{url=\"$3\",protocolBinding=\"jsonrpc\"}]" \
      --format="value(registryResource)" 2>&1)"; then
    echo "${out##*$'\n'}"
  elif echo "${out}" | grep -qi 'ALREADY_EXISTS\|already exists'; then
    echo "(already registered)"       # safe to re-run
  else
    local detail
    detail="$(echo "${out}" | grep -v 'Create request issued\|Waiting for operation\|^{$\|^}$' | tail -1)"
    # an empty error body usually means the URL is already registered under
    # a different service name
    echo "FAILED ${detail:-(empty error — URL may already be registered under another name)}"
  fi
}

registry() {
  for c in services endpoints mcpServers agents; do
    echo "--- ${c}"
    curl -sS -H "$(auth)" \
      "https://agentregistry.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/${c}" \
      | python3 -c "
import json,sys
for k,v in json.load(sys.stdin).items():
    if isinstance(v,list):
        for x in v: print('   %-46s %s' % (x['name'].split('/')[-1], x.get('displayName','')))"
  done
}

# ------------------------------------------------------------------------------
# 1d. The IAM grant. Registration alone allows nothing — the agent's identity
# also needs roles/iap.egressor on the destination.
#
# This grants EVERY agent in the project access to EVERY registered
# destination — the simplest thing that works, and fine for the baseline
# Google APIs. See 3-register-mcp.sh for the least-privilege alternative
# (one agent -> one MCP server).
#
# NOTE: pass a BARE {"bindings": [...]} object. Wrapping it in
# {"policy": {...}} (as some docs show) is rejected by gcloud.
# ------------------------------------------------------------------------------
grant_all() {
  local f; f="$(mktemp)"
  cat > "$f" <<EOF
{"bindings":[{"role":"roles/iap.egressor","members":["${PROJECT_PRINCIPAL}"]}]}
EOF
  gcloud beta iap web set-iam-policy "$f" --project="${PROJECT_ID}" \
    --resource-type=agent-registry --region="${LOCATION}" --quiet
  rm -f "$f"
}

grants() {
  gcloud beta iap web get-iam-policy --project="${PROJECT_ID}" \
    --resource-type=agent-registry --region="${LOCATION}"
}

# ------------------------------------------------------------------------------
# Observe. Every governed connection writes one entry to the
# gateway_requests log — this is where you discover what to register.
# ------------------------------------------------------------------------------
logs() {
  gcloud logging read \
    'logName:"networkservices.googleapis.com%2Fgateway_requests"' \
    --project="${PROJECT_ID}" --freshness="${1:-1h}" --limit=200 --format=json \
    | python3 -c "
import json,sys
print('%-46s %-9s %s' % ('HOSTNAME','VERDICT','REGISTRY MATCH'))
print('-'*86)
seen=set()
for e in json.load(sys.stdin):
    p=e.get('jsonPayload',{})
    host=(p.get('enforcedGatewaySecurityPolicy') or {}).get('hostname')
    if not host or host.startswith('240.0.0.'): continue  # internal sentinel, no SNI
    verdict=(p.get('authzPolicyInfo') or {}).get('result')
    match=(p.get('agentGatewayInfo') or {}).get('agentRegistryResource','')
    row=(host,str(verdict),match.split('/')[-1] or '(UNREGISTERED)')
    if row not in seen:
        seen.add(row); print('%-46s %-9s %s' % row)"
}

# ------------------------------------------------------------------------------
# Teardown — order matters: policy, then extension, then gateway.
# (Detach or delete any bound agent first — see 2-deploy-agent.py teardown.)
# ------------------------------------------------------------------------------
teardown() {
  gcloud beta network-security authz-policies delete "${GATEWAY_ID}-iap-authzpolicy" \
    --location="${LOCATION}" --project="${PROJECT_ID}" --quiet || true
  gcloud beta service-extensions authz-extensions delete "${GATEWAY_ID}-iap-authzextension" \
    --location="${LOCATION}" --project="${PROJECT_ID}" --quiet || true
  curl -sS -X DELETE -H "$(auth)" \
    "${NS}/projects/${PROJECT_ID}/locations/${LOCATION}/agentGateways/${GATEWAY_ID}" | head -c 300
  echo
}

all() {
  create_gateway
  wait_gateway
  create_authz
  register_baseline
  grant_all
  echo
  echo "Done. Next: deploy the dummy MCP server (see README step 2)."
}

"${@:-gateways}"
