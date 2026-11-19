data "vsphere_datacenter" "this" {
  name = var.datacenter_name
}

data "vsphere_datastore" "vm" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.this.id
}

data "vsphere_datastore" "iso" {
  count         = var.iso_datastore_name == null ? 0 : 1
  name          = var.iso_datastore_name
  datacenter_id = data.vsphere_datacenter.this.id
}

# Hosts must already exist as standalone hosts in vCenter inventory.
data "vsphere_host" "esxi" {
  for_each      = toset(var.cluster.esxi_hosts)
  name          = each.value
  datacenter_id = data.vsphere_datacenter.this.id
}

# Witness host for a vSAN stretched cluster. It must already exist in vCenter.
data "vsphere_host" "vsan_witness" {
  count         = var.cluster.vsan.stretched_cluster.witness_host == "" ? 0 : 1
  name          = var.cluster.vsan.stretched_cluster.witness_host
  datacenter_id = data.vsphere_datacenter.this.id
}

# Only used when create_networks = false.
data "vsphere_network" "existing" {
  for_each      = var.cluster.create_networks ? {} : var.cluster.existing_networks
  name          = each.value
  datacenter_id = data.vsphere_datacenter.this.id
}

# One template per cloned machine. Templates are registered by
# scripts/prepare-vm-images.ps1 (Linux) or maintained in vCenter (Windows).
data "vsphere_virtual_machine" "template" {
  for_each      = local.template_names
  name          = each.value
  datacenter_id = data.vsphere_datacenter.this.id
  folder        = var.template_folder == "" ? null : var.template_folder
}
