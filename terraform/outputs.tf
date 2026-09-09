output "gateway" {
  description = "Agent Gateway resource name."
  value       = google_network_services_agent_gateway.egress.id
}

output "gateway_root_certificates" {
  description = "CA the gateway re-signs TLS with — bake into bring-your-own-container images."
  value       = try(google_network_services_agent_gateway.egress.agent_gateway_card[0].root_certificates, null)
  sensitive   = true
}

output "mcp_url" {
  description = "MCP endpoint of the dummy weather server."
  value       = local.mcp_url
}

output "mcp_server_registry_id" {
  description = "Agent Registry mcpServers id for the MCP server."
  value       = local.mcp_server_id
}

output "agent_resource_name" {
  description = "Reasoning engine resource name of the ADK agent."
  value       = var.deploy_agent ? google_vertex_ai_reasoning_engine.adk[0].id : null
}

output "agent_principal" {
  description = "Agent Identity principal the gateway authorizes."
  value       = var.deploy_agent ? local.agent_principal : null
}

output "gemini_enterprise_assistant" {
  description = "Assistant the agent was registered under (empty when registration is skipped)."
  value       = local.ge_enabled ? local.ge_assistant : null
}

output "enforcement_mode" {
  value = var.enforcement_mode
}
