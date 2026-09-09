# Everything the demo touches. disable_on_destroy=false so a destroy does not
# yank APIs out from under other workloads in the project.
locals {
  apis = [
    "aiplatform.googleapis.com",
    "networkservices.googleapis.com",
    "networksecurity.googleapis.com",
    "iap.googleapis.com",
    "agentregistry.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "discoveryengine.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "project" {
  project_id = var.project_id
  depends_on = [google_project_service.apis]
}

# The org id builds the Agent Identity trust domain. data.google_project only
# knows it for projects directly under the org, so fall back to the ancestry.
data "external" "org_id" {
  count   = var.org_id == "" ? 1 : 0
  program = ["bash", "${path.module}/scripts/org_id.sh", var.project_id]
}

locals {
  project_number = data.google_project.project.number
  org_id         = var.org_id != "" ? var.org_id : data.external.org_id[0].result.org_id

  # Agent Identity trust domain — the principal prefix the gateway authorizes.
  trust_domain = "agents.global.org-${local.org_id}.system.id.goog"

  # Every agent in the project, present and future.
  project_principal = "principalSet://${local.trust_domain}/attribute.platformContainer/aiplatform/projects/${local.project_number}"
}
