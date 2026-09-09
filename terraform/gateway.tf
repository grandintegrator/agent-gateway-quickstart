# ------------------------------------------------------------------------------
# The gateway: a managed proxy in the network path of every bound agent.
#
#   agent ──▶ [ AGENT_TO_ANYWHERE gateway ] ──▶ MCP servers, A2A agents, APIs
#
# `registries` must be the REGIONAL registry for Agent Engine agents. Point it
# at the global registry and every destination reads as unregistered.
# ------------------------------------------------------------------------------
resource "google_network_services_agent_gateway" "egress" {
  name        = var.gateway_id
  location    = var.location
  project     = var.project_id
  description = "Governs agent -> MCP server / A2A / API egress"

  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }

  registries = [
    "//agentregistry.googleapis.com/projects/${var.project_id}/locations/${var.location}",
  ]

  depends_on = [google_project_service.apis]

  timeouts {
    create = "30m"
    delete = "30m"
  }
}
