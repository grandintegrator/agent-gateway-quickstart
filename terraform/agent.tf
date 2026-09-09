# ------------------------------------------------------------------------------
# The ADK agent (agent/), deployed FROM SOURCE: the directory is tarred at plan
# time and handed to Agent Engine, which builds the container. No pickling.
#
# Three things make the gateway demo work, all set at CREATE time:
#   identity_type        = AGENT_IDENTITY   (mandatory for any gateway binding)
#   agent_gateway_config = the gateway      (the binding itself)
#   MCP_URL              = the MCP server   (so the MCP toolset knows where to go)
#
# depends_on encodes what the API does not: the baseline allowlist and the
# registry-wide grant must exist BEFORE the agent is created, or the deploy
# fails ~13 minutes later because the agent cannot reach Vertex AI.
# ------------------------------------------------------------------------------
data "external" "agent_source" {
  program = ["bash", "${path.module}/scripts/tar_b64.sh", "${path.module}/..", "agent"]
}

resource "google_vertex_ai_reasoning_engine" "adk" {
  count        = var.deploy_agent ? 1 : 0
  project      = var.project_id
  region       = var.location
  display_name = var.agent_display_name
  description  = "ADK weather agent governed by Agent Gateway"

  # Sessions are child resources; without FORCE a destroy fails once the
  # agent has been talked to.
  deletion_policy = "FORCE"

  spec {
    agent_framework = "google-adk"
    identity_type   = "AGENT_IDENTITY"

    # The AdkApp operations. Source deploys must declare them, otherwise
    # :streamQuery (what Gemini Enterprise calls) is not exposed.
    class_methods = file("${path.module}/../agent/class_methods.json")

    source_code_spec {
      inline_source {
        source_archive = data.external.agent_source.result.b64
      }
      python_spec {
        entrypoint_module = "agent.agent_engine_app" # root_agent wrapped in AdkApp
        entrypoint_object = "app"
        requirements_file = "agent/requirements.txt"
        version           = "3.12"
      }
    }

    deployment_spec {
      env {
        name  = "MCP_URL"
        value = local.mcp_url
      }
      env {
        name  = "MODEL"
        value = var.agent_model
      }
      env {
        # Not read by the agent — it makes a source change show up as a diff,
        # since source_archive is input-only and cannot be diffed.
        name  = "AGENT_SOURCE_SHA"
        value = data.external.agent_source.result.sha
      }
      agent_gateway_config {
        agent_to_anywhere_config {
          agent_gateway = google_network_services_agent_gateway.egress.id
        }
      }
    }
  }

  depends_on = [
    google_network_security_authz_policy.iap,
    google_agent_registry_service.baseline,
    google_iap_agent_registry_iam_member.all_agents,
    google_agent_registry_service.mcp,
  ]

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }
}

locals {
  agent_identity  = var.deploy_agent ? google_vertex_ai_reasoning_engine.adk[0].spec[0].effective_identity : ""
  agent_principal = var.deploy_agent ? "principal://${local.agent_identity}" : ""
}

# An LLM agent must be allowed to call Vertex AI. A trivial agent never needs
# this; an ADK agent running as its own Agent Identity does.
resource "google_project_iam_member" "agent_vertex_user" {
  count   = var.deploy_agent ? 1 : 0
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = local.agent_principal
}

# Least privilege: THIS agent -> THIS MCP server. (The baseline grant above
# already covers the MCP server too; this shows the per-destination shape.)
resource "google_iap_agent_registry_mcp_server_iam_member" "agent_to_mcp" {
  count         = var.deploy_agent ? 1 : 0
  project       = var.project_id
  location      = var.location
  mcp_server_id = local.mcp_server_id
  role          = "roles/iap.egressor"
  member        = local.agent_principal
}
