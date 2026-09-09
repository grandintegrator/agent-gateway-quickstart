# ------------------------------------------------------------------------------
# Register the agent in an EXISTING Gemini Enterprise app.
#
# There is no Terraform resource for assistants/*/agents yet, so this is a
# terraform_data with an idempotent script: upsert on apply, delete on destroy.
# Gemini Enterprise drives the agent through :streamQuery, hence the ADK agent.
# ------------------------------------------------------------------------------
locals {
  ge_enabled        = var.deploy_agent && var.gemini_enterprise_app_id != ""
  ge_project_number = var.gemini_enterprise_project_number != "" ? var.gemini_enterprise_project_number : local.project_number
  ge_endpoint       = var.gemini_enterprise_location == "global" ? "https://discoveryengine.googleapis.com" : "https://${var.gemini_enterprise_location}-discoveryengine.googleapis.com"
  ge_assistant      = "projects/${local.ge_project_number}/locations/${var.gemini_enterprise_location}/collections/default_collection/engines/${var.gemini_enterprise_app_id}/assistants/default_assistant"
}

# Gemini Enterprise's service agent must be allowed to invoke the reasoning engine.
resource "google_project_iam_member" "ge_service_agent" {
  for_each = local.ge_enabled ? toset(["roles/aiplatform.user", "roles/aiplatform.viewer"]) : toset([])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:service-${local.ge_project_number}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
}

resource "terraform_data" "ge_agent" {
  count = local.ge_enabled ? 1 : 0

  input = {
    endpoint         = local.ge_endpoint
    assistant        = local.ge_assistant
    project_id       = var.project_id
    reasoning_engine = google_vertex_ai_reasoning_engine.adk[0].id
    display_name     = var.gemini_enterprise_display_name
    description      = var.gemini_enterprise_description
    scope            = var.publish_to_all_users ? "ALL_USERS" : "RESTRICTED"
    script           = abspath("${path.module}/scripts/ge_agent.sh")
  }

  # Any input change re-runs the upsert (the script matches on reasoning engine).
  triggers_replace = [var.gemini_enterprise_display_name, var.gemini_enterprise_description, var.publish_to_all_users]

  provisioner "local-exec" {
    command = "${self.input.script} upsert"
    environment = {
      DE_ENDPOINT      = self.input.endpoint
      GE_ASSISTANT     = self.input.assistant
      PROJECT_ID       = self.input.project_id
      REASONING_ENGINE = self.input.reasoning_engine
      DISPLAY_NAME     = self.input.display_name
      DESCRIPTION      = self.input.description
      SCOPE            = self.input.scope
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${self.input.script} delete"
    environment = {
      DE_ENDPOINT      = self.input.endpoint
      GE_ASSISTANT     = self.input.assistant
      PROJECT_ID       = self.input.project_id
      REASONING_ENGINE = self.input.reasoning_engine
    }
  }

  depends_on = [google_project_iam_member.ge_service_agent, google_project_iam_member.agent_vertex_user]
}
