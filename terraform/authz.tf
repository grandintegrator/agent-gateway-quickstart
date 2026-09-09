# ------------------------------------------------------------------------------
# The IAP enforcement hook. A gateway with no authz policy enforces NOTHING.
#
# DRY_RUN + fail_open=true logs denials but lets traffic through, so you can
# discover the real dependency list before anything breaks. Flip
# var.enforcement_mode to ENFORCED once the gateway_requests log is clean —
# it is an in-place update of the extension.
# ------------------------------------------------------------------------------
resource "google_network_services_authz_extension" "iap" {
  name      = "${var.gateway_id}-iap-authzextension"
  location  = var.location
  project   = var.project_id
  service   = "iap.googleapis.com"
  timeout   = "10s"
  fail_open = var.enforcement_mode == "DRY_RUN"

  metadata = {
    iamEnforcementMode = var.enforcement_mode
    iapPolicyVersion   = "V1"
  }

  depends_on = [google_project_service.apis]
}

resource "google_network_security_authz_policy" "iap" {
  name           = "${var.gateway_id}-iap-authzpolicy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [
      "projects/${local.project_number}/locations/${var.location}/agentGateways/${google_network_services_agent_gateway.egress.name}",
    ]
  }

  custom_provider {
    authz_extension {
      resources = [
        "projects/${local.project_number}/locations/${var.location}/authzExtensions/${google_network_services_authz_extension.iap.name}",
      ]
    }
  }
}
