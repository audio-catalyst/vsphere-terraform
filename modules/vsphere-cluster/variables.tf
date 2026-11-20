# =============================================================================
# vCenter connection (values come from globals.json + TF_VAR_vsphere_password)
# =============================================================================

variable "vsphere_server" {
  description = "FQDN or IP address of the vCenter Server."
  type        = string
}

variable "vsphere_user" {
  description = "vCenter user allowed to manage clusters, hosts, networking and VMs."
  type        = string
}

variable "vsphere_password" {
  description = "Password for vsphere_user. Supplied via TF_VAR_vsphere_password."
  type        = string
  sensitive   = true
}

variable "allow_unverified_ssl" {
  description = "Accept self-signed vCenter certificates. Set to false in production and trust the real CA."
  type        = bool
  default     = false
}

# =============================================================================
# Inventory / placement
# =============================================================================

variable "datacenter_name" {
  description = "Inventory name of the vSphere datacenter."
  type        = string
}

variable "datastore_name" {
  description = "Datastore for VM configuration files and virtual disks."
  type        = string
}

variable "iso_datastore_name" {
  description = "Datastore holding the ISO files referenced by machines[*].iso_path. Set to null when no machine uses an ISO."
  type        = string
  default     = null

  validation {
    condition = var.iso_datastore_name != null || (
      alltrue([for m in var.machines : m.iso_path == null]) &&
      alltrue([
        for name, m in var.machines :
        !(try(var.machine_images[name].kind, null) == "windows" && try(m.vmtools.enabled, try(var.cluster.vmtools.enabled, false)))
      ])
    )
    error_message = "iso_datastore_name must be set when a machine defines iso_path or when VMware Tools installation is enabled for a Windows clone."
  }
}

variable "vm_hardware_version" {
  description = "Optional virtual hardware version, e.g. 20 for vSphere 8. Leave null to use the host default."
  type        = number
  default     = null
}

# =============================================================================
# Cluster item (cluster.json)
# =============================================================================

variable "cluster" {
  description = "Cluster settings, hosts, vSAN and VDS configuration decoded from cluster.json."
  type = object({
    name                                        = string
    folder                                      = optional(string, "")
    drs_enabled                                 = optional(bool, true)
    drs_automation_level                        = optional(string, "fullyAutomated")
    drs_migration_threshold                     = optional(number, 3)
    ha_enabled                                  = optional(bool, true)
    ha_host_monitoring                          = optional(string, "enabled")
    ha_vm_monitoring                            = optional(string, "vmMonitoringDisabled")
    ha_admission_control_policy                 = optional(string, "resourcePercentage")
    ha_admission_control_host_failure_tolerance = optional(number, 1)
    evc_mode                                    = optional(string, null)
    host_cluster_exit_timeout                   = optional(number, 3600)

    esxi_hosts = optional(list(string), [])

    vsan = optional(object({
      enabled                         = optional(bool, false)
      esa_enabled                     = optional(bool, false)
      unmap_enabled                   = optional(bool, false)
      dedup_enabled                   = optional(bool, false)
      compression_enabled             = optional(bool, false)
      performance_enabled             = optional(bool, true)
      verbose_mode_enabled            = optional(bool, false)
      network_diagnostic_mode_enabled = optional(bool, false)

      dit_encryption_enabled = optional(bool, false)
      dit_rekey_interval     = optional(number, 1440)
      remote_datastore_ids   = optional(set(string), [])

      # One entry per disk group. The provider applies each entry to every host
      # in the cluster that has the listed canonical disk names.
      disk_groups = optional(list(object({
        cache   = string
        storage = set(string)
      })), [])

      # Fault domain name => host inventory names (mutually exclusive with a
      # stretched cluster).
      fault_domains = optional(map(list(string)), {})

      # Set witness_host to enable a stretched cluster. Leave empty otherwise.
      stretched_cluster = optional(object({
        preferred_hosts       = list(string)
        secondary_hosts       = list(string)
        witness_host          = string
        preferred_domain_name = optional(string, "Preferred")
        secondary_domain_name = optional(string, "Secondary")
        }), {
        preferred_hosts       = []
        secondary_hosts       = []
        witness_host          = ""
        preferred_domain_name = "Preferred"
        secondary_domain_name = "Secondary"
      })
    }), {})

    create_networks   = optional(bool, true)
    existing_networks = optional(map(string), {})

    vds = optional(object({
      name            = string
      uplinks         = list(string)
      active_uplinks  = list(string)
      standby_uplinks = optional(list(string), [])
      max_mtu         = optional(number, 1500)
      host_uplinks    = map(list(string))
      }), {
      name            = "vds-managed"
      uplinks         = ["uplink1", "uplink2"]
      active_uplinks  = ["uplink1", "uplink2"]
      standby_uplinks = []
      max_mtu         = 1500
      host_uplinks    = {}
    })

    # Optional first-boot Ansible bootstrap for every VM in this cluster.
    # Machines can override every field in their own JSON file.
    ansible = optional(object({
      enabled           = optional(bool, false)
      repository        = optional(string, null)
      playbook          = optional(string, "site.yml")
      branch            = optional(string, "main")
      directory         = optional(string, null)
      requirements_file = optional(string, null)
      extra_vars        = optional(map(string), {})
      package_name      = optional(string, "ansible-core")
      install_packages  = optional(bool, true)
      run_pull          = optional(bool, true)
    }), {})

    # Windows clone settings: install VMware Tools from an ISO on the ISO
    # datastore and upgrade Tools automatically at each power cycle.
    # Omit this object entirely to leave Windows VMs untouched.
    vmtools = optional(object({
      enabled        = optional(bool, true)
      iso_path       = optional(string, null)
      installer_args = optional(string, "/S /v\"/qn REBOOT=ReallySuppress\"")
      upgrade_policy = optional(string, "upgradeAtPowerCycle")
    }), {})
  })

  validation {
    condition     = length(trimspace(var.cluster.name)) > 0
    error_message = "cluster.name must not be empty."
  }

  validation {
    condition     = contains(["manual", "partiallyAutomated", "fullyAutomated"], var.cluster.drs_automation_level)
    error_message = "cluster.drs_automation_level must be manual, partiallyAutomated or fullyAutomated."
  }

  validation {
    condition     = var.cluster.drs_migration_threshold >= 1 && var.cluster.drs_migration_threshold <= 5
    error_message = "cluster.drs_migration_threshold must be between 1 and 5."
  }

  # --- vSAN ---

  validation {
    condition     = !var.cluster.vsan.dedup_enabled || var.cluster.vsan.compression_enabled
    error_message = "vSAN deduplication requires compression to also be enabled (not supported with ESA)."
  }

  validation {
    condition     = !(var.cluster.vsan.esa_enabled && (var.cluster.vsan.dedup_enabled || var.cluster.vsan.compression_enabled))
    error_message = "vSAN ESA cannot be combined with deduplication or compression."
  }

  validation {
    condition     = !var.cluster.vsan.esa_enabled || var.cluster.vsan.unmap_enabled
    error_message = "vSAN unmap must be enabled when ESA is enabled."
  }

  validation {
    condition     = !(var.cluster.vsan.dit_encryption_enabled && length(var.cluster.vsan.remote_datastore_ids) > 0)
    error_message = "vSAN data-in-transit encryption conflicts with HCI Mesh remote datastores."
  }

  validation {
    condition     = var.cluster.vsan.dit_rekey_interval >= 30 && var.cluster.vsan.dit_rekey_interval <= 10080
    error_message = "vSAN DIT rekey interval must be between 30 and 10080 minutes."
  }

  validation {
    condition     = length(var.cluster.vsan.remote_datastore_ids) <= 5
    error_message = "At most 5 vSAN remote datastore IDs are supported."
  }

  validation {
    condition     = !(length(var.cluster.vsan.fault_domains) > 0 && var.cluster.vsan.stretched_cluster.witness_host != "")
    error_message = "vSAN fault_domains and stretched_cluster are mutually exclusive."
  }

  validation {
    condition = alltrue([
      for hosts in var.cluster.vsan.fault_domains : alltrue([
        for h in hosts : contains(var.cluster.esxi_hosts, h)
      ])
    ])
    error_message = "Every host in a vSAN fault domain must also be listed in esxi_hosts."
  }

  validation {
    condition = var.cluster.vsan.stretched_cluster.witness_host == "" ? true : (
      length(var.cluster.vsan.stretched_cluster.preferred_hosts) > 0 &&
      length(var.cluster.vsan.stretched_cluster.secondary_hosts) > 0
    )
    error_message = "A stretched cluster needs at least one preferred and one secondary host."
  }

  validation {
    condition = var.cluster.vsan.stretched_cluster.witness_host == "" ? true : alltrue([
      for h in concat(
        var.cluster.vsan.stretched_cluster.preferred_hosts,
        var.cluster.vsan.stretched_cluster.secondary_hosts
      ) : contains(var.cluster.esxi_hosts, h)
    ])
    error_message = "Every stretched cluster data host must also be listed in esxi_hosts."
  }

  # --- Networking ---

  validation {
    condition     = var.cluster.create_networks || length(var.cluster.existing_networks) > 0
    error_message = "When create_networks = false, existing_networks must map every network name."
  }

  validation {
    condition     = alltrue([for h in keys(var.cluster.vds.host_uplinks) : contains(var.cluster.esxi_hosts, h)])
    error_message = "Every key in vds.host_uplinks must also appear in esxi_hosts."
  }

  validation {
    condition     = alltrue([for h in var.cluster.vds.host_uplinks : length(h) == length(var.cluster.vds.uplinks)])
    error_message = "Each vds.host_uplinks entry must list one physical NIC per uplink, in uplink order."
  }

  validation {
    condition     = alltrue([for u in concat(var.cluster.vds.active_uplinks, var.cluster.vds.standby_uplinks) : contains(var.cluster.vds.uplinks, u)])
    error_message = "active_uplinks and standby_uplinks must be subsets of vds.uplinks."
  }

  validation {
    condition     = !var.cluster.ansible.enabled || length(trimspace(try(var.cluster.ansible.repository, ""))) > 0
    error_message = "cluster.ansible.enabled requires a non-empty ansible.repository URL."
  }

  validation {
    condition     = contains(["manual", "upgradeAtPowerCycle"], try(var.cluster.vmtools.upgrade_policy, "upgradeAtPowerCycle"))
    error_message = "cluster.vmtools.upgrade_policy must be manual or upgradeAtPowerCycle."
  }
}

# =============================================================================
# Network items (networks/*.json, one file per port group)
# =============================================================================

variable "networks" {
  description = "Logical network name => port group settings, decoded from networks/*.json."
  type = map(object({
    vlan_id     = number
    type        = optional(string, "earlyBinding")
    description = optional(string, "")
  }))

  validation {
    condition     = length(var.networks) > 0
    error_message = "Define at least one network JSON file."
  }

  validation {
    condition     = alltrue([for n in values(var.networks) : n.vlan_id >= 0 && n.vlan_id <= 4094])
    error_message = "Network vlan_id must be between 0 and 4094."
  }

  validation {
    condition     = alltrue([for n in values(var.networks) : contains(["earlyBinding", "ephemeral"], n.type)])
    error_message = "Network type must be earlyBinding or ephemeral."
  }

  validation {
    condition     = var.cluster.create_networks || setequals(keys(var.networks), keys(var.cluster.existing_networks))
    error_message = "When create_networks = false, existing_networks must define exactly the same keys as the network JSON files."
  }
}

# =============================================================================
# Machine items (machines/*.json, one file per VM)
# =============================================================================

variable "machines" {
  description = "Machine name => VM settings, decoded from machines/*.json."
  type = map(object({
    name                 = string
    num_cpus             = number
    memory               = number
    disk_size            = optional(number, null)
    guest_id             = optional(string, null)
    firmware             = optional(string, "bios")
    disk_label           = optional(string, "disk0")
    thin_provisioned     = optional(bool, true)
    scsi_type            = optional(string, "pvscsi")
    network_adapter_type = optional(string, "vmxnet3")
    networks             = list(string)
    iso_path             = optional(string, null)
    annotation           = optional(string, "")

    # OS selection. When "os" is set the VM is cloned from the template
    # resolved from images/catalog.json; without it the legacy blank-VM +
    # optional ISO behaviour is kept.
    os            = optional(string, null)
    version       = optional(string, null)
    variant       = optional(string, null)
    template_name = optional(string, null)

    # Guest customisation (only used for cloned VMs).
    hostname        = optional(string, null)
    domain          = optional(string, "local")
    ipv4_address    = optional(string, null)
    ipv4_netmask    = optional(number, null)
    ipv4_gateway    = optional(string, null)
    dns_server_list = optional(list(string), [])
    dns_suffix_list = optional(list(string), [])

    # Optional per-VM override of the cluster-wide Ansible bootstrap.
    # Any field left null inherits the cluster value. "enabled": false
    # disables the bootstrap even when the cluster enables it.
    ansible = optional(object({
      enabled           = optional(bool, null)
      repository        = optional(string, null)
      playbook          = optional(string, null)
      branch            = optional(string, null)
      directory         = optional(string, null)
      requirements_file = optional(string, null)
      extra_vars        = optional(map(string), null)
      package_name      = optional(string, null)
      install_packages  = optional(bool, null)
      run_pull          = optional(bool, null)
    }), null)

    # Per-VM override of VMware Tools installation for Windows clones.
    vmtools = optional(object({
      enabled        = optional(bool, null)
      iso_path       = optional(string, null)
      installer_args = optional(string, null)
      upgrade_policy = optional(string, null)
    }), null)
  }))

  validation {
    condition = alltrue([
      for m in var.machines :
      length(trimspace(m.name)) > 0 && m.num_cpus > 0 && m.memory > 0 &&
      (m.disk_size == null || m.disk_size > 0)
    ])
    error_message = "Each machine needs a non-empty name, positive num_cpus and memory, and a positive disk_size when set."
  }

  validation {
    condition = alltrue([
      for m in var.machines :
      try(m.os, null) == null || (
        contains(["centos", "rockylinux", "almalinux", "ubuntu", "debian", "windows"], m.os) &&
        try(m.version, null) != null && length(trimspace(m.version)) > 0
      )
    ])
    error_message = "machine.os must be centos, rockylinux, almalinux, ubuntu, debian or windows and machine.version is required when os is set."
  }

  validation {
    condition = alltrue([
      for m in var.machines :
      try(m.os, null) != null || (m.guest_id != null && m.disk_size != null)
    ])
    error_message = "Machines without an OS selection (legacy blank VMs) must set guest_id and disk_size."
  }

  validation {
    condition = alltrue([
      for m in var.machines : alltrue([
        for n in m.networks : contains(keys(var.networks), n)
      ])
    ])
    error_message = "Every machine network must match a networks/*.json file name."
  }

  validation {
    condition     = alltrue([for m in var.machines : contains(["bios", "efi"], m.firmware)])
    error_message = "machine.firmware must be bios or efi."
  }

  validation {
    condition     = alltrue([for m in var.machines : contains(["e1000", "e1000e", "vmxnet3", "sriov"], m.network_adapter_type)])
    error_message = "machine.network_adapter_type must be e1000, e1000e, vmxnet3 or sriov."
  }
}

# =============================================================================
# OS image templates (resolved from images/catalog.json by the root module)
# =============================================================================

variable "machine_images" {
  description = "Machine name => OS image resolved from images/catalog.json. Empty for legacy blank VMs."
  type = map(object({
    os           = string
    version      = string
    variant      = string
    kind         = string
    templateName = string
    guestId      = string
    diskSize     = number
  }))
  default = {}
}

variable "template_folder" {
  description = "vCenter VM folder that contains the image templates."
  type        = string
  default     = ""
}

variable "windows_admin_password" {
  description = "Local administrator password used to sysprep cloned Windows VMs. Provide via TF_VAR_windows_admin_password."
  type        = string
  sensitive   = true
  default     = null
}
