# ------------------------------------------------------------------------------
# The allowlist (Agent Registry) and the grant (IAP). Traffic flows only when
# a destination is BOTH registered AND covered by roles/iap.egressor for the
# agent's identity.
#
# THE STEP EVERYONE MISSES: the gateway fronts EVERYTHING, including the
# agent's own calls to Vertex AI, Cloud Trace and Cloud Logging. Without this
# baseline an agent bound to the gateway fails to deploy ~13 minutes later
# with only "The Reasoning Engine failed to be updated".
#
# Matching is by EXACT hostname and Google client libraries mostly egress via
# *.mtls.googleapis.com — register both forms. Service ids match the ones
# 1-setup-gateway.sh creates, so an existing registry can be imported.
# ------------------------------------------------------------------------------
locals {
  baseline = {
    "allow-aiplatform"        = { name = "Vertex AI ${var.location}", url = "https://${var.location}-aiplatform.googleapis.com" }
    "allow-aiplatform-mtls"   = { name = "Vertex AI mTLS", url = "https://${var.location}-aiplatform.mtls.googleapis.com" }
    "allow-aiplatform-rep"    = { name = "Vertex AI rep", url = "https://aiplatform.${var.location}.rep.googleapis.com" }
    "allow-aiplatform-global" = { name = "Vertex AI global mTLS", url = "https://aiplatform.mtls.googleapis.com" }
    "allow-telemetry"         = { name = "Cloud Trace", url = "https://telemetry.googleapis.com" }
    "allow-telemetry-mtls"    = { name = "Cloud Trace mTLS", url = "https://telemetry.mtls.googleapis.com" }
    "allow-logging"           = { name = "Cloud Logging", url = "https://logging.googleapis.com" }
    "allow-logging-mtls"      = { name = "Cloud Logging mTLS", url = "https://logging.mtls.googleapis.com" }
    "allow-crm"               = { name = "ResourceManager", url = "https://cloudresourcemanager.googleapis.com" }
    "allow-crm-mtls"          = { name = "ResourceManager mTLS", url = "https://cloudresourcemanager.mtls.googleapis.com" }
    # gRPC clients present host:443 and matching is exact; the ADK runtime's
    # telemetry setup calls Resource Manager over gRPC at boot.
    "allow-crm-mtls-grpc" = { name = "ResourceManager mTLS gRPC", url = "https://cloudresourcemanager.mtls.googleapis.com:443" }
    "allow-iamcreds"      = { name = "IAM Credentials", url = "https://iamcredentials.googleapis.com" }
    "allow-iamcreds-mtls" = { name = "IAM Credentials mTLS", url = "https://iamcredentials.mtls.googleapis.com" }
  }
}

resource "google_agent_registry_service" "baseline" {
  for_each     = local.baseline
  project      = var.project_id
  location     = var.location
  service_id   = each.key
  display_name = each.value.name

  interfaces {
    url              = each.value.url
    protocol_binding = "JSONRPC"
  }

  endpoint_spec {
    type = "NO_SPEC"
  }

  depends_on = [google_project_service.apis]
}

# Every agent in the project may reach every registered destination — the
# simplest thing that works, and fine for the baseline Google APIs. The MCP
# server below additionally gets a per-agent grant to show least privilege.
resource "google_iap_agent_registry_iam_member" "all_agents" {
  project  = var.project_id
  location = var.location
  role     = "roles/iap.egressor"
  member   = local.project_principal

  depends_on = [google_agent_registry_service.baseline]
}
