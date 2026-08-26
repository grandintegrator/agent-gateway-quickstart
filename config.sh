# Shared configuration for the shell scripts.
#
# Either edit the values below, or export the variables before running a
# script — an exported value always wins.

: "${PROJECT_ID:=your-project-id}"
: "${PROJECT_NUMBER:=123456789012}"   # gcloud projects describe $PROJECT_ID --format='value(projectNumber)'
: "${ORG_ID:=123456789012}"           # gcloud organizations list
: "${LOCATION:=us-central1}"          # gateway, agent and registry must all be in the same region
: "${GATEWAY_ID:=demo-egress-gw}"

export PROJECT_ID PROJECT_NUMBER ORG_ID LOCATION GATEWAY_ID

# Agent Identity trust domain — the principal prefix the gateway authorizes.
export TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"

# Every agent in the project, present and future:
export PROJECT_PRINCIPAL="principalSet://${TRUST_DOMAIN}/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"

export NS="https://networkservices.googleapis.com/v1"
export AIP="https://${LOCATION}-aiplatform.googleapis.com/v1beta1"

auth() { echo "Authorization: Bearer $(gcloud auth print-access-token)"; }
