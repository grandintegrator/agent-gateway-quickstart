#!/usr/bin/env bash
# Idempotent Gemini Enterprise registration for a reasoning engine.
#   ge_agent.sh upsert   create or update the agent under $GE_ASSISTANT, set sharing scope
#   ge_agent.sh delete   remove it
# Env: DE_ENDPOINT GE_ASSISTANT PROJECT_ID REASONING_ENGINE [DISPLAY_NAME DESCRIPTION SCOPE]
set -euo pipefail
: "${DE_ENDPOINT:?}" "${GE_ASSISTANT:?}" "${PROJECT_ID:?}" "${REASONING_ENGINE:?}"
AGENTS_URL="${DE_ENDPOINT}/v1alpha/${GE_ASSISTANT}/agents"

_curl() {
  curl -sS -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "x-goog-user-project: ${PROJECT_ID}" -H "Content-Type: application/json" "$@"
}

_existing() {
  _curl "${AGENTS_URL}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'error' in d: sys.exit('list failed: '+json.dumps(d['error']))
for a in d.get('agents',[]):
    re=((a.get('adkAgentDefinition') or {}).get('provisionedReasoningEngine') or {}).get('reasoningEngine','')
    if re.split('/')[-1]=='${REASONING_ENGINE##*/}': print(a['name']); break"
}

upsert() {
  : "${DISPLAY_NAME:?}" "${DESCRIPTION:?}" "${SCOPE:=RESTRICTED}"
  local body; body="$(python3 - <<'PY'
import json, os
print(json.dumps({
  "displayName": os.environ["DISPLAY_NAME"],
  "description": os.environ["DESCRIPTION"],
  "icon": {"uri": "https://fonts.gstatic.com/s/i/short-term/release/googlesymbols/smart_toy/default/24px.svg"},
  "adkAgentDefinition": {
    "toolSettings": {"toolDescription": os.environ["DESCRIPTION"]},
    "provisionedReasoningEngine": {"reasoningEngine": os.environ["REASONING_ENGINE"]},
  },
  "sharingConfig": {"scope": os.environ["SCOPE"]},
}))
PY
)"
  local name; name="$(_existing)"
  local out
  if [ -n "${name}" ]; then
    out="$(_curl -X PATCH "${DE_ENDPOINT}/v1alpha/${name}?updateMask=displayName,description,icon,adkAgentDefinition,sharingConfig" -d "${body}")"
  else
    out="$(_curl -X POST "${AGENTS_URL}" -d "${body}")"
  fi
  echo "${out}" | python3 -c "
import json,sys
a=json.load(sys.stdin)
if 'error' in a: sys.exit('registration failed: '+json.dumps(a['error']))
print('gemini enterprise agent:', a.get('name'), a.get('state'))"
}

delete() {
  local name; name="$(_existing)"
  [ -n "${name}" ] || { echo "no registration for ${REASONING_ENGINE}"; exit 0; }
  _curl -X DELETE "${DE_ENDPOINT}/v1alpha/${name}" >/dev/null && echo "deleted ${name}"
}

"${1:?upsert|delete}"
