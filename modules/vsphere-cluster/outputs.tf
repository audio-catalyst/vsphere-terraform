output "cluster" {
  description = "Compute cluster details."
  value = {
    id               = vsphere_compute_cluster.this.id
    name             = vsphere_compute_cluster.this.name
    resource_pool_id = vsphere_compute_cluster.this.resource_pool_id
  }
}

output "esxi_host_ids" {
  description = "ESXi host name => managed object ID."
  value       = { for name, host in data.vsphere_host.esxi : name => host.id }
}

output "vds_id" {
  description = "ID of the managed distributed switch, or null when create_networks = false."
  value       = var.cluster.create_networks ? vsphere_distributed_virtual_switch.this[0].id : null
}

output "network_ids" {
  description = "Logical network name => vSphere network managed object ID."
  value       = local.network_ids
}

output "machines" {
  description = "Machine name => VM managed object ID."
  value       = { for name, vm in vsphere_virtual_machine.machine : name => vm.id }
}

output "vsan" {
  description = "vSAN configuration summary."
  value = {
    enabled           = var.cluster.vsan.enabled
    esa_enabled       = var.cluster.vsan.esa_enabled
    disk_groups       = length(var.cluster.vsan.disk_groups)
    fault_domains     = keys(var.cluster.vsan.fault_domains)
    stretched_cluster = var.cluster.vsan.stretched_cluster.witness_host != ""
  }
}
