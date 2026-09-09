#!/usr/bin/env bash
#
# Step 6 — register the ADK agent in a Gemini Enterprise app.
#
# Gemini Enterprise drives an agent through reasoningEngines:streamQuery, so
# the agent must be an ADK agent (2-deploy-agent.py deploy-adk) — the trivial
# agent from step 3 has no such method. The registration itself is a Discovery
# Engine resource under the app's default assistant.
#
# Two things must be true before the UI can use the agent:
#   - Gemini Enterprise's service agent may invoke reasoning engines (grant)
#   - the agent may reach the MCP server through the gateway     (grant)
#
# Usage:
#   ./4-register-gemini-enterprise.sh grant     # IAM, both of the above
#   ./4-register-gemini-enterprise.sh register  # create or update the registration (PRIVATE)
#   ./4-register-gemini-enterprise.sh publish   # PRIVATE -> ENABLED for all users of the app
#   ./4-register-gemini-enterprise.sh ask "What is the weather in Melbourne?"   # via the assistant API
#   ./4-register-gemini-enterprise.sh status
#   ./4-register-gemini-enterprise.sh remove
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME:-gateway-demo-adk-agent}"
export GE_DISPLAY_NAME="${GE_DISPLAY_NAME:-Gateway demo weather agent}"
export GE_DESCRIPTION="${GE_DESCRIPTION:-Answers weather questions via an MCP server. Every outbound call is governed by Agent Gateway.}"

if [ "${GE_LOCATION}" = "global" ]; then DE="https://discoveryengine.googleapis.com"
else DE="https://${GE_LOCATION}-discoveryengine.googleapis.com"; fi
ASSISTANT="projects/${GE_PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}/assistants/default_assistant"
AGENTS_URL="${DE}/v1alpha/${ASSISTANT}/agents"

# curl against Discovery Engine. x-goog-user-project is the billing project.
_curl() {
  curl -sS -H "$(auth)" -H "x-goog-user-project: ${PROJECT_ID}" \
    -H "Content-Type: application/json" "$@"
}

# Numeric id of the deployed ADK agent, by display name.
_agent_id() {
  curl -sS -H "$(auth)" \
    "${AIP}/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines?pageSize=100" \
    | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('reasoningEngines',[]):
    if r.get('displayName')=='${AGENT_DISPLAY_NAME}':
        print(r['name'].split('/')[-1]); break"
}

# The Gemini Enterprise registration that points at our reasoning engine, if any.
_ge_name() {
  _curl "${AGENTS_URL}" | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('agents',[]):
    re=((a.get('adkAgentDefinition') or {}).get('provisionedReasoningEngine') or {}).get('reasoningEngine','')
    if re.endswith('/reasoningEngines/$1'): print(a['name']); break"
}

_need_agent() {
  AGENT_ID="$(_agent_id)"
  [ -n "${AGENT_ID}" ] || { echo "agent '${AGENT_DISPLAY_NAME}' not found — run 2-deploy-agent.py deploy-adk first"; exit 1; }
}

grant() {
  # 6a. Gemini Enterprise's service agent must be allowed to invoke the reasoning engine.
  local ge_sa="serviceAccount:service-${GE_PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
  for role in roles/aiplatform.user roles/aiplatform.viewer; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${ge_sa}" --role="${role}" \
      --condition=None --quiet >/dev/null && echo "granted ${role} to ${ge_sa}"
  done
  # 6b. Least-privilege egress: THIS agent -> the MCP server (step 4, for the other agent).
  AGENT_DISPLAY_NAME="${AGENT_DISPLAY_NAME}" ./3-register-mcp.sh grant
}

register() {
  _need_agent
  local engine="projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines/${AGENT_ID}"
  local body; body="$(python3 - "${engine}" <<'PY'
import json, os, sys
print(json.dumps({
  "displayName": os.environ["GE_DISPLAY_NAME"],
  "description": os.environ["GE_DESCRIPTION"],
  "icon": {"uri": "https://fonts.gstatic.com/s/i/short-term/release/googlesymbols/smart_toy/default/24px.svg"},
  "adkAgentDefinition": {
    "toolSettings": {"toolDescription": os.environ["GE_DESCRIPTION"]},
    "provisionedReasoningEngine": {"reasoningEngine": sys.argv[1]},
  },
}))
PY
)"
  local existing; existing="$(_ge_name "${AGENT_ID}")"
  if [ -n "${existing}" ]; then
    echo "==> updating ${existing}" >&2
    _curl -X PATCH "${DE}/v1alpha/${existing}?updateMask=displayName,description,icon,adkAgentDefinition" -d "${body}"
  else
    echo "==> creating registration under ${ASSISTANT}" >&2
    _curl -X POST "${AGENTS_URL}" -d "${body}"
  fi | python3 -c "
import json,sys; a=json.load(sys.stdin)
if 'error' in a: sys.exit('registration failed: ' + json.dumps(a['error'], indent=2))
print(json.dumps({k:a[k] for k in ('name','displayName','state') if k in a}, indent=2))"
  echo "A new registration is PRIVATE (creator only). Run 'publish' to enable it for all users of the app."
}

publish() {
  _need_agent
  local name; name="$(_ge_name "${AGENT_ID}")"
  [ -n "${name}" ] || { echo "not registered yet — run register first"; exit 1; }
  _curl -X PATCH "${DE}/v1alpha/${name}?updateMask=sharingConfig" \
    -d '{"sharingConfig":{"scope":"ALL_USERS"}}' \
    | python3 -c "import json,sys; a=json.load(sys.stdin); print(a.get('name'), a.get('state'), a.get('error',''))"
}

# Ask the question through the app's assistant, routed to our agent — the
# same path the Gemini Enterprise UI takes.
ask() {
  _need_agent
  local name; name="$(_ge_name "${AGENT_ID}")"
  [ -n "${name}" ] || { echo "not registered yet — run register first"; exit 1; }
  local q="${1:-What is the weather in Melbourne?}"
  _curl -X POST "${DE}/v1alpha/${ASSISTANT}:streamAssist" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'query':{'text':sys.argv[1]},'agentsConfig':{'agent':sys.argv[2]}}))" "${q}" "${name}")" \
    | python3 -c "
import json,sys
raw=sys.stdin.read()
try: chunks=json.loads(raw)
except Exception: print(raw[:1500]); sys.exit(0)
if isinstance(chunks,dict): chunks=[chunks]
text=''
for c in chunks:
    if 'error' in c: print(json.dumps(c['error'],indent=2)); continue
    for r in (c.get('answer') or {}).get('replies',[]):
        for p in ((r.get('groundedContent') or {}).get('content') or {}).get('parts',[]):
            text+=p.get('text','')
print(text.strip() or json.dumps(chunks)[:1500])"
}

status() {
  echo "--- agents registered in ${GE_APP_ID} (${GE_LOCATION})"
  _curl "${AGENTS_URL}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: print(json.dumps(d['error'],indent=2)); sys.exit(1)
print('%-40s %-9s %s' % ('DISPLAY NAME','STATE','REASONING ENGINE'))
for a in d.get('agents',[]):
    re=((a.get('adkAgentDefinition') or {}).get('provisionedReasoningEngine') or {}).get('reasoningEngine','')
    print('%-40s %-9s %s' % (a.get('displayName'), a.get('state'), re.split('/')[-1] if re else '(not ADK)'))"
}

remove() {
  _need_agent
  local name; name="$(_ge_name "${AGENT_ID}")"
  [ -n "${name}" ] || { echo "nothing registered for ${AGENT_DISPLAY_NAME}"; exit 0; }
  _curl -X DELETE "${DE}/v1alpha/${name}" | head -c 300; echo
  echo "removed ${name}"
}

"${@:-status}"
