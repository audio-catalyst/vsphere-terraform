locals {
  managed_network_ids = {
    for name, pg in vsphere_distributed_port_group.this : name => pg.id
  }

  existing_network_ids = {
    for name, net in data.vsphere_network.existing : name => net.id
  }

  network_ids = var.cluster.create_networks ? local.managed_network_ids : local.existing_network_ids

  # Image settings resolved by the root module from images/catalog.json.
  image_lookup = {
    for name, machine in var.machines : name => try(var.machine_images[name], null)
  }

  # A machine is cloned when it selects an OS (or overrides the template name).
  template_names = {
    for name, machine in var.machines : name =>
    machine.template_name != null ? machine.template_name : try(local.image_lookup[name].templateName, null)
    if machine.template_name != null || try(local.image_lookup[name].templateName, null) != null
  }

  guest_ids = {
    for name, machine in var.machines : name =>
    machine.guest_id != null ? machine.guest_id : try(local.image_lookup[name].guestId, "otherGuest")
  }

  disk_sizes = {
    for name, machine in var.machines : name =>
    machine.disk_size != null ? machine.disk_size : try(local.image_lookup[name].diskSize, 0)
  }

  # --- Optional first-boot Ansible bootstrap ---------------------------------
  # The cluster sets defaults; each machine JSON can override or disable them.
  ansible_defaults = try(var.cluster.ansible, {})

  ansible_directory_override = {
    for name, machine in var.machines : name =>
    try(machine.ansible.directory, null) != null ? machine.ansible.directory : (
      try(local.ansible_defaults.directory, null) != null ? local.ansible_defaults.directory : ""
    )
  }

  ansible_linux_directory = {
    for name, directory in local.ansible_directory_override : name =>
    directory != "" ? directory : "/opt/ansible-pull"
  }

  ansible_windows_directory = {
    for name, directory in local.ansible_directory_override : name =>
    directory != "" ? directory : "C:\\ansible-pull"
  }

  ansible_effective = {
    for name, machine in var.machines : name => {
      enabled = try(machine.ansible.enabled, null) != null ? machine.ansible.enabled : try(local.ansible_defaults.enabled, false)

      repository = try(machine.ansible.repository, null) != null ? machine.ansible.repository : try(local.ansible_defaults.repository, null)
      playbook   = try(machine.ansible.playbook, null) != null ? machine.ansible.playbook : try(local.ansible_defaults.playbook, "site.yml")
      branch     = try(machine.ansible.branch, null) != null ? machine.ansible.branch : try(local.ansible_defaults.branch, "main")

      requirements_file = try(machine.ansible.requirements_file, null) != null ? machine.ansible.requirements_file : try(local.ansible_defaults.requirements_file, null)
      extra_vars        = try(machine.ansible.extra_vars, null) != null ? machine.ansible.extra_vars : try(local.ansible_defaults.extra_vars, {})
      package_name      = try(machine.ansible.package_name, null) != null ? machine.ansible.package_name : try(local.ansible_defaults.package_name, "ansible-core")

      install_packages = coalesce(try(machine.ansible.install_packages, null), try(local.ansible_defaults.install_packages, true))
      run_pull         = coalesce(try(machine.ansible.run_pull, null), try(local.ansible_defaults.run_pull, true))

      os_family = try(local.image_lookup[name].kind, "linux") == "windows" ? "windows" : "linux"
      directory = local.ansible_directory_override[name]
    }
  }

  # Optional strings must be normalised before base64encode: coalesce(null, "")
  # is an error in Terraform because both arguments are skipped.
  ansible_repository = {
    for name, config in local.ansible_effective : name => config.repository == null ? "" : config.repository
  }

  ansible_requirements = {
    for name, config in local.ansible_effective : name => config.requirements_file == null ? "" : config.requirements_file
  }

  # JSON is handed to the guest scripts as base64 so no shell quoting is needed.
  ansible_json = {
    for name, config in local.ansible_effective : name => jsonencode({
      repository        = local.ansible_repository[name]
      playbook          = config.playbook
      branch            = config.branch
      directory         = config.os_family == "windows" ? local.ansible_windows_directory[name] : local.ansible_linux_directory[name]
      requirements_file = local.ansible_requirements[name]
      extra_vars        = config.extra_vars
      package_name      = config.package_name
      install_packages  = config.install_packages
      run_pull          = config.run_pull
    })
  }

  ansible_linux_scripts = {
    for name, config in local.ansible_effective : name => templatefile("${path.module}/templates/ansible-linux.sh.tpl", {
      repo_b64         = base64encode(local.ansible_repository[name])
      playbook_b64     = base64encode(config.playbook)
      branch_b64       = base64encode(config.branch)
      directory_b64    = base64encode(local.ansible_linux_directory[name])
      requirements_b64 = base64encode(local.ansible_requirements[name])
      package_b64      = base64encode(config.package_name)
      extra_vars_b64   = base64encode(local.ansible_json[name])
      install_packages = config.install_packages ? "true" : "false"
      run_pull         = config.run_pull ? "true" : "false"
    })
  }

  ansible_windows_scripts = {
    for name, config in local.ansible_effective : name => templatefile("${path.module}/templates/ansible-windows.ps1.tpl", {
      repo_b64         = base64encode(local.ansible_repository[name])
      playbook_b64     = base64encode(config.playbook)
      branch_b64       = base64encode(config.branch)
      directory_b64    = base64encode(local.ansible_windows_directory[name])
      requirements_b64 = base64encode(local.ansible_requirements[name])
      package_b64      = base64encode(config.package_name)
      extra_vars_b64   = base64encode(local.ansible_json[name])
      install_packages = config.install_packages ? "true" : "false"
      run_pull         = config.run_pull ? "true" : "false"
    })
  }

  # Windows Sysprep runs commands, not scripts, so wrap the generated PS1.
  ansible_windows_run_once = {
    for name, script in local.ansible_windows_scripts : name => templatefile("${path.module}/templates/ansible-windows-run-once.tpl", {
      script_b64 = base64encode(script)
    })
  }

  # Guest customisation for clones. A static address is applied to the first
  # NIC only; additional NICs use DHCP.
  customize_specs = {
    for name, machine in var.machines : name =>
    contains(keys(local.template_names), name) && (
      try(local.image_lookup[name].kind, "linux") == "linux" || var.windows_admin_password != null
      ) ? {
      os_family       = try(local.image_lookup[name].kind, "linux") == "windows" ? "windows" : "linux"
      hostname        = coalesce(machine.hostname, machine.name)
      domain          = machine.domain
      ipv4_gateway    = machine.ipv4_gateway
      dns_server_list = machine.dns_server_list
      dns_suffix_list = machine.dns_suffix_list
      networks = [
        for index, network in machine.networks : {
          ipv4_address = index == 0 ? machine.ipv4_address : null
          ipv4_netmask = index == 0 ? machine.ipv4_netmask : null
        }
      ]
    } : null
  }
}

check "image_disk_sizes" {
  assert {
    condition     = alltrue([for name, size in local.disk_sizes : size > 0])
    error_message = "Every machine needs a positive disk_size, either in its JSON file or in images/catalog.json."
  }
}

check "windows_admin_password" {
  assert {
    condition = alltrue([
      for name, machine in var.machines :
      try(local.image_lookup[name].kind, "linux") != "windows" || var.windows_admin_password != null
    ])
    error_message = "Set TF_VAR_windows_admin_password when cloning Windows templates."
  }
}

# Each machine JSON file name must match the "name" inside that file.
check "machine_file_names" {
  assert {
    condition     = alltrue([for file_name, machine in var.machines : file_name == machine.name])
    error_message = "Each machine JSON file name must match its \"name\" value."
  }
}

check "ansible_configuration" {
  assert {
    condition = alltrue([
      for name, config in local.ansible_effective :
      !config.enabled || (
        config.repository != null && length(trimspace(config.repository)) > 0 &&
        length(trimspace(config.playbook)) > 0 &&
        length(trimspace(config.branch)) > 0 &&
        length(trimspace(config.package_name)) > 0
      )
    ])
    error_message = "Every VM with Ansible enabled needs a non-empty repository, playbook, branch and package_name."
  }
}

resource "vsphere_compute_cluster" "this" {
  name                      = var.cluster.name
  datacenter_id             = data.vsphere_datacenter.this.id
  folder                    = var.cluster.folder
  host_system_ids           = [for host in data.vsphere_host.esxi : host.id]
  host_cluster_exit_timeout = var.cluster.host_cluster_exit_timeout
  force_evacuate_on_destroy = false

  drs_enabled             = var.cluster.drs_enabled
  drs_automation_level    = var.cluster.drs_automation_level
  drs_migration_threshold = var.cluster.drs_migration_threshold

  ha_enabled                                  = var.cluster.ha_enabled
  ha_host_monitoring                          = var.cluster.ha_host_monitoring
  ha_vm_monitoring                            = var.cluster.ha_vm_monitoring
  ha_admission_control_policy                 = var.cluster.ha_admission_control_policy
  ha_admission_control_host_failure_tolerance = var.cluster.ha_admission_control_host_failure_tolerance

  evc_mode = var.cluster.evc_mode

  # vSAN. The provider applies these settings before the general cluster
  # configuration (which includes HA), so vSAN can be enabled in one apply.
  vsan_enabled                         = var.cluster.vsan.enabled
  vsan_esa_enabled                     = var.cluster.vsan.esa_enabled
  vsan_unmap_enabled                   = var.cluster.vsan.unmap_enabled
  vsan_dedup_enabled                   = var.cluster.vsan.dedup_enabled
  vsan_compression_enabled             = var.cluster.vsan.compression_enabled
  vsan_performance_enabled             = var.cluster.vsan.performance_enabled
  vsan_verbose_mode_enabled            = var.cluster.vsan.verbose_mode_enabled
  vsan_network_diagnostic_mode_enabled = var.cluster.vsan.network_diagnostic_mode_enabled

  vsan_dit_encryption_enabled = var.cluster.vsan.dit_encryption_enabled
  vsan_dit_rekey_interval     = var.cluster.vsan.dit_rekey_interval
  vsan_remote_datastore_ids   = var.cluster.vsan.remote_datastore_ids

  dynamic "vsan_disk_group" {
    for_each = var.cluster.vsan.disk_groups
    content {
      cache   = vsan_disk_group.value.cache
      storage = vsan_disk_group.value.storage
    }
  }

  dynamic "vsan_fault_domains" {
    for_each = length(var.cluster.vsan.fault_domains) > 0 ? [1] : []
    content {
      dynamic "fault_domain" {
        for_each = var.cluster.vsan.fault_domains
        content {
          name     = fault_domain.key
          host_ids = [for host in fault_domain.value : data.vsphere_host.esxi[host].id]
        }
      }
    }
  }

  dynamic "vsan_stretched_cluster" {
    for_each = var.cluster.vsan.stretched_cluster.witness_host == "" ? [] : [1]
    content {
      preferred_fault_domain_host_ids = [
        for host in var.cluster.vsan.stretched_cluster.preferred_hosts : data.vsphere_host.esxi[host].id
      ]
      secondary_fault_domain_host_ids = [
        for host in var.cluster.vsan.stretched_cluster.secondary_hosts : data.vsphere_host.esxi[host].id
      ]
      witness_node                = data.vsphere_host.vsan_witness[0].id
      preferred_fault_domain_name = var.cluster.vsan.stretched_cluster.preferred_domain_name
      secondary_fault_domain_name = var.cluster.vsan.stretched_cluster.secondary_domain_name
    }
  }
}

resource "vsphere_distributed_virtual_switch" "this" {
  count         = var.cluster.create_networks ? 1 : 0
  name          = var.cluster.vds.name
  datacenter_id = data.vsphere_datacenter.this.id

  uplinks         = var.cluster.vds.uplinks
  active_uplinks  = var.cluster.vds.active_uplinks
  standby_uplinks = var.cluster.vds.standby_uplinks
  max_mtu         = var.cluster.vds.max_mtu

  dynamic "host" {
    for_each = var.cluster.vds.host_uplinks
    content {
      host_system_id = data.vsphere_host.esxi[host.key].id
      devices        = host.value
    }
  }
}

resource "vsphere_distributed_port_group" "this" {
  for_each = var.cluster.create_networks ? var.networks : {}

  name                            = each.key
  distributed_virtual_switch_uuid = vsphere_distributed_virtual_switch.this[0].id

  vlan_id     = each.value.vlan_id
  type        = each.value.type
  description = each.value.description
  auto_expand = true
}

resource "vsphere_virtual_machine" "machine" {
  for_each = var.machines

  name             = each.value.name
  resource_pool_id = vsphere_compute_cluster.this.resource_pool_id
  datastore_id     = data.vsphere_datastore.vm.id

  num_cpus   = each.value.num_cpus
  memory     = each.value.memory
  guest_id   = local.guest_ids[each.key]
  annotation = each.value.annotation

  # Staged for every VM, including blank ones: cloud-init/cloudbase-init can
  # consume these guestinfo values, and the scripts can also be run manually.
  extra_config = local.ansible_effective[each.key].enabled ? {
    "guestinfo.ansible.enabled"           = "true"
    "guestinfo.ansible.repository"        = base64encode(local.ansible_repository[each.key])
    "guestinfo.ansible.playbook"          = base64encode(local.ansible_effective[each.key].playbook)
    "guestinfo.ansible.branch"            = base64encode(local.ansible_effective[each.key].branch)
    "guestinfo.ansible.directory.linux"   = base64encode(local.ansible_linux_directory[each.key])
    "guestinfo.ansible.directory.windows" = base64encode(local.ansible_windows_directory[each.key])
    "guestinfo.ansible.requirements"      = base64encode(local.ansible_requirements[each.key])
    "guestinfo.ansible.extra_vars"        = base64encode(local.ansible_json[each.key])
    "guestinfo.ansible.package"           = base64encode(local.ansible_effective[each.key].package_name)
    "guestinfo.ansible.install_packages"  = local.ansible_effective[each.key].install_packages ? "true" : "false"
    "guestinfo.ansible.run_pull"          = local.ansible_effective[each.key].run_pull ? "true" : "false"
    "guestinfo.ansible.bootstrap.linux"   = base64encode(local.ansible_linux_scripts[each.key])
    "guestinfo.ansible.bootstrap.windows" = base64encode(local.ansible_windows_scripts[each.key])
  } : {}

  # Clones inherit firmware, SCSI controller and hardware version from their
  # template; those settings only apply to the legacy blank-VM path.
  firmware         = contains(keys(local.template_names), each.key) ? null : each.value.firmware
  scsi_type        = contains(keys(local.template_names), each.key) ? null : each.value.scsi_type
  hardware_version = contains(keys(local.template_names), each.key) ? null : var.vm_hardware_version

  disk {
    label            = each.value.disk_label
    size             = local.disk_sizes[each.key]
    thin_provisioned = each.value.thin_provisioned
    eagerly_scrub    = false
  }

  dynamic "network_interface" {
    for_each = toset(each.value.networks)
    content {
      network_id   = local.network_ids[network_interface.value]
      adapter_type = each.value.network_adapter_type
    }
  }

  dynamic "clone" {
    for_each = contains(keys(local.template_names), each.key) ? [1] : []
    content {
      template_uuid = data.vsphere_virtual_machine.template[each.key].id

      dynamic "customize" {
        for_each = local.customize_specs[each.key] == null ? [] : [1]
        content {
          dynamic "linux_options" {
            for_each = local.customize_specs[each.key].os_family == "linux" ? [1] : []
            content {
              host_name   = local.customize_specs[each.key].hostname
              domain      = local.customize_specs[each.key].domain
              script_text = local.ansible_effective[each.key].enabled ? local.ansible_linux_scripts[each.key] : null
            }
          }

          dynamic "windows_options" {
            for_each = local.customize_specs[each.key].os_family == "windows" ? [1] : []
            content {
              computer_name         = local.customize_specs[each.key].hostname
              admin_password        = var.windows_admin_password
              run_once_command_list = local.ansible_effective[each.key].enabled ? [local.ansible_windows_run_once[each.key]] : null
            }
          }

          dynamic "network_interface" {
            for_each = local.customize_specs[each.key].networks
            content {
              ipv4_address = network_interface.value.ipv4_address
              ipv4_netmask = network_interface.value.ipv4_netmask
            }
          }

          ipv4_gateway    = local.customize_specs[each.key].ipv4_gateway
          dns_server_list = local.customize_specs[each.key].dns_server_list
          dns_suffix_list = local.customize_specs[each.key].dns_suffix_list
        }
      }
    }
  }

  dynamic "cdrom" {
    for_each = each.value.iso_path == null || contains(keys(local.template_names), each.key) ? [] : [1]
    content {
      datastore_id = data.vsphere_datastore.iso[0].id
      path         = each.value.iso_path
    }
  }

  # Guest tooling may not be ready immediately after a clone, so keep the
  # waiters disabled rather than failing the apply on slow guests.
  wait_for_guest_net_timeout = 0
  wait_for_guest_ip_timeout  = 0

  lifecycle {
    # vSphere/guest tooling may normalise this after first boot.
    ignore_changes = [annotation]
  }
}
