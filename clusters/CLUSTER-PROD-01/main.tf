# -----------------------------------------------------------------------------
# Root module for one vSphere cluster.
#
# Everything that differs between clusters lives in the JSON files next to
# this file (cluster.json, networks/*.json, machines/*.json). Shared vCenter
# settings live in ../../globals.json. Each folder has its own state.
# -----------------------------------------------------------------------------

variable "vsphere_password" {
  description = "vCenter password. Provide via TF_VAR_vsphere_password."
  type        = string
  sensitive   = true
}

variable "windows_admin_password" {
  description = "Local administrator password for Windows guest customisation. Provide via TF_VAR_windows_admin_password."
  type        = string
  sensitive   = true
  default     = null
}

locals {
  globals = jsondecode(file("${path.module}/../../globals.json"))

  cluster = jsondecode(file("${path.module}/cluster.json"))

  # One JSON file per port group; the file name is the logical network name.
  network_files = fileset("${path.module}/networks", "*.json")
  networks = {
    for f in local.network_files :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/networks/${f}"))
  }

  # One JSON file per VM; the file name must match the "name" inside the file.
  machine_files = fileset("${path.module}/machines", "*.json")
  machines = {
    for f in local.machine_files :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/machines/${f}"))
  }

  # OS image catalog, shared by all clusters.
  catalog = jsondecode(file("${path.module}/../../images/catalog.json"))

  catalog_images = {
    for image in local.catalog.images :
    "${image.os}|${image.version}|${coalesce(try(image.variant, null), "default")}" => image
  }

  machine_images = {
    for name, machine in local.machines : name =>
    local.catalog_images["${machine.os}|${machine.version}|${coalesce(try(machine.variant, null), "default")}"]
    if try(machine.os, null) != null
  }
}

check "machine_image_catalog" {
  assert {
    condition = alltrue([
      for name, machine in local.machines :
      try(machine.os, null) == null || contains(
        keys(local.catalog_images),
        "${machine.os}|${machine.version}|${coalesce(try(machine.variant, null), "default")}"
      )
    ])
    error_message = "A machine requests an os/version/variant that is not in images/catalog.json."
  }
}

provider "vsphere" {
  user                 = local.globals.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = local.globals.vsphere_server
  allow_unverified_ssl = local.globals.allow_unverified_ssl
}

module "cluster" {
  source = "../../modules/vsphere-cluster"

  vsphere_server       = local.globals.vsphere_server
  vsphere_user         = local.globals.vsphere_user
  vsphere_password     = var.vsphere_password
  allow_unverified_ssl = local.globals.allow_unverified_ssl

  datacenter_name     = local.globals.datacenter_name
  datastore_name      = local.globals.datastore_name
  iso_datastore_name  = local.globals.iso_datastore_name
  vm_hardware_version = local.globals.vm_hardware_version

  cluster  = local.cluster
  networks = local.networks
  machines = local.machines

  machine_images         = local.machine_images
  template_folder        = try(local.catalog.defaults.templateFolder, "TerraformTemplates")
  windows_admin_password = var.windows_admin_password
}

output "cluster" {
  description = "Compute cluster details for this cluster folder."
  value       = module.cluster.cluster
}

output "esxi_host_ids" {
  description = "ESXi host name => managed object ID."
  value       = module.cluster.esxi_host_ids
}

output "vds_id" {
  description = "ID of the managed distributed switch, or null when create_networks = false."
  value       = module.cluster.vds_id
}

output "network_ids" {
  description = "Logical network name => vSphere network managed object ID."
  value       = module.cluster.network_ids
}

output "machines" {
  description = "Machine name => VM managed object ID."
  value       = module.cluster.machines
}

output "vsan" {
  description = "vSAN configuration summary."
  value       = module.cluster.vsan
}
