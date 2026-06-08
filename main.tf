

terraform {
  required_providers {
    meraki = {
      source  = "ciscodevnet/meraki"
      version = ">= 1.9.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9.0"
    }
  }
}

module "meraki" {
  source           = "github.com/netascode/terraform-meraki-nac-meraki?ref=v0.5.0"
  yaml_directories = ["data"]
}

# ---------------------------------------------------------------------------
# Firmware upgrades are not supported in the NAC module YAML data model
# (v0.5.0), so this resource is managed directly in Terraform.
# ---------------------------------------------------------------------------

variable "org_name" {
  description = "Meraki organization name — set via TF_VAR_org_name (same value as $org_name env var)"
  type        = string
}

data "meraki_organization" "this" {
  depends_on = [module.meraki]
  name       = var.org_name
}

data "meraki_network" "gsa_cloud_fabric" {
  depends_on      = [module.meraki]
  organization_id = data.meraki_organization.this.id
  name            = "gsa-cloud-fabric"
}

# Meraki's backend needs time to fully provision a newly created network
# before the firmware upgrades API will accept requests without a 500.
resource "time_sleep" "wait_for_network_provisioning" {
  depends_on      = [data.meraki_network.gsa_cloud_fabric]
  create_duration = "60s"
}

# Pins Catalyst switches to cs-iosxe-17-18-3 (ID 15052) after network creation.
# The ciscodevnet/meraki provider sends nextUpgrade.toVersion.id as a string but
# the Meraki API requires an integer, causing a 500 on every apply via the provider.
# Calling the API directly with curl bypasses the type mismatch.
# A 4xx response means the switch is already on this version — treated as success.
resource "terraform_data" "firmware_pin_gsa_cloud_fabric" {
  depends_on       = [time_sleep.wait_for_network_provisioning]
  triggers_replace = [data.meraki_network.gsa_cloud_fabric.id]

  provisioner "local-exec" {
    environment = {
      NETWORK_ID = data.meraki_network.gsa_cloud_fabric.id
    }
    command = <<-EOT
      RESPONSE=$(curl -s -L -w "\n%%{http_code}" -X PUT \
        "https://api.meraki.com/api/v1/networks/$NETWORK_ID/firmwareUpgrades" \
        -H "X-Cisco-Meraki-API-Key: $MERAKI_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"products":{"switchCatalyst":{"participateInNextBetaRelease":true,"nextUpgrade":{"toVersion":{"id":15052}}}}}')
      HTTP_CODE=$(echo "$RESPONSE" | tail -1)
      BODY=$(echo "$RESPONSE" | head -1)
      echo "HTTP $HTTP_CODE: $BODY"
      [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 500 ]
    EOT
  }
}
