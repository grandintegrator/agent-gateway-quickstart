# ------------------------------------------------------------------------------
# The dummy MCP server (mcp-server/) on Cloud Run, registered WITH its tool
# list. MCP is the one protocol whose request bodies the gateway parses, so a
# registered tool list is what enables per-TOOL authorization.
#
# The image is built with Cloud Build buildpacks from mcp-server/ (Procfile +
# requirements.txt) unless var.mcp_image points at a prebuilt image. The build
# is the one non-declarative step in this module: the GA provider has no
# "build a plain Cloud Run service from source" resource.
# ------------------------------------------------------------------------------
locals {
  mcp_src        = "${path.module}/../mcp-server"
  mcp_src_hash   = sha256(join("", [for f in fileset(local.mcp_src, "**") : filesha256("${local.mcp_src}/${f}")]))
  mcp_repo_image = "${var.location}-docker.pkg.dev/${var.project_id}/${var.mcp_service_name}/${var.mcp_service_name}"
  mcp_image      = var.mcp_image != "" ? var.mcp_image : "${local.mcp_repo_image}:${substr(local.mcp_src_hash, 0, 12)}"
}

resource "google_artifact_registry_repository" "mcp" {
  count         = var.mcp_image == "" ? 1 : 0
  project       = var.project_id
  location      = var.location
  repository_id = var.mcp_service_name
  format        = "DOCKER"
  description   = "Images for the ${var.mcp_service_name} demo MCP server"

  depends_on = [google_project_service.apis]
}

resource "terraform_data" "mcp_build" {
  count = var.mcp_image == "" ? 1 : 0

  triggers_replace = [local.mcp_image]

  provisioner "local-exec" {
    command = <<-CMD
      gcloud builds submit "${local.mcp_src}" \
        --project="${var.project_id}" --region="${var.location}" \
        --pack image="${local.mcp_image}" --quiet
    CMD
  }

  depends_on = [google_artifact_registry_repository.mcp]
}

resource "google_cloud_run_v2_service" "mcp" {
  provider            = google-beta
  project             = var.project_id
  name                = var.mcp_service_name
  location            = var.location
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  # The demo agent calls the MCP server unauthenticated; the gateway is the
  # control point. Org policies often forbid an allUsers binding, so the
  # invoker check is disabled instead (same as --no-invoker-iam-check).
  invoker_iam_disabled = var.mcp_invoker_iam_disabled

  template {
    containers {
      image = local.mcp_image
      ports {
        container_port = 8080
      }
    }
  }

  depends_on = [terraform_data.mcp_build, google_project_service.apis]
}

resource "google_cloud_run_v2_service_iam_member" "mcp_public" {
  count    = var.mcp_invoker_iam_disabled ? 0 : 1
  project  = var.project_id
  location = var.location
  name     = google_cloud_run_v2_service.mcp.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

locals {
  mcp_url = "${google_cloud_run_v2_service.mcp.uri}/mcp"
}

resource "google_agent_registry_service" "mcp" {
  project      = var.project_id
  location     = var.location
  service_id   = var.mcp_service_name
  display_name = var.mcp_service_name
  description  = "Dummy weather MCP server (canned data)"

  interfaces {
    url              = local.mcp_url
    protocol_binding = "JSONRPC"
  }

  mcp_server_spec {
    type    = "TOOL_SPEC"
    content = file("${local.mcp_src}/tools.json")
  }
}

locals {
  # registry_resource is projects/.../mcpServers/<id>; the IAM resource wants the id.
  mcp_server_id = element(split("/", google_agent_registry_service.mcp.registry_resource), length(split("/", google_agent_registry_service.mcp.registry_resource)) - 1)
}
