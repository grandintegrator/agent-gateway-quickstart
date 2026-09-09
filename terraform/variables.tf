variable "project_id" {
  description = "Project that hosts the gateway, registry, MCP server and agent."
  type        = string
}

variable "location" {
  description = "Region for the gateway, registry, MCP server and agent. They must all share one region."
  type        = string
  default     = "us-central1"
}

variable "org_id" {
  description = "Organization id, used to build the Agent Identity trust domain. Leave empty to read it from the project."
  type        = string
  default     = ""
}

variable "gateway_id" {
  description = "Name of the AGENT_TO_ANYWHERE Agent Gateway."
  type        = string
  default     = "demo-egress-gw"
}

variable "enforcement_mode" {
  description = "IAP enforcement mode for the gateway: DRY_RUN logs denials but lets traffic through; ENFORCED blocks."
  type        = string
  default     = "DRY_RUN"
  validation {
    condition     = contains(["DRY_RUN", "ENFORCED"], var.enforcement_mode)
    error_message = "enforcement_mode must be DRY_RUN or ENFORCED."
  }
}

variable "mcp_service_name" {
  description = "Cloud Run service name for the dummy weather MCP server (also its registry service id)."
  type        = string
  default     = "demo-weather-mcp"
}

variable "mcp_image" {
  description = "Prebuilt image for the MCP server. Leave empty to build mcp-server/ with Cloud Build buildpacks."
  type        = string
  default     = ""
}

variable "mcp_invoker_iam_disabled" {
  description = "Serve the MCP server without an invoker IAM check (the gateway demo calls it unauthenticated). Set false if your org policy allows allUsers and you prefer an IAM binding."
  type        = bool
  default     = true
}

variable "deploy_agent" {
  description = "Deploy the ADK agent (agent/) to Agent Engine, bound to the gateway with Agent Identity."
  type        = bool
  default     = true
}

variable "agent_display_name" {
  description = "Display name of the ADK agent in Agent Engine."
  type        = string
  default     = "gateway-demo-adk-agent"
}

variable "agent_model" {
  description = "Gemini model used by the ADK agent."
  type        = string
  default     = "gemini-2.5-flash"
}

variable "gemini_enterprise_app_id" {
  description = "Engine id of an EXISTING Gemini Enterprise app (e.g. my-app_1234567890). Empty = skip registration."
  type        = string
  default     = ""
}

variable "gemini_enterprise_location" {
  description = "Location of the Gemini Enterprise app: global, us or eu."
  type        = string
  default     = "global"
}

variable "gemini_enterprise_project_number" {
  description = "Project number that owns the Gemini Enterprise app. Empty = this project."
  type        = string
  default     = ""
}

variable "gemini_enterprise_display_name" {
  description = "How the agent appears in Gemini Enterprise."
  type        = string
  default     = "Gateway demo weather agent"
}

variable "gemini_enterprise_description" {
  description = "Agent description shown in Gemini Enterprise (also used as the tool description)."
  type        = string
  default     = "Answers weather questions via an MCP server. Every outbound call is governed by Agent Gateway."
}

variable "publish_to_all_users" {
  description = "Share the registered agent with all users of the app (ENABLED) instead of its creator only (PRIVATE)."
  type        = bool
  default     = false
}
