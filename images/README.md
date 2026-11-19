# OS image catalog

`catalog.json` is the single source of truth for the OS a machine can boot. It
maps `os` + `version` + `variant` to a vCenter template, guest ID, disk size and
( for Linux) the verified LinuxVMImages download.

## Catalog entry format

```json
{
  "os": "rockylinux",
  "version": "9",
  "variant": "minimal",
  "release": "9.4",
  "kind": "linux",
  "sourcePage": "https://www.linuxvmimages.com/images/rockylinux-9/",
  "downloadUrl": "https://sourceforge.net/.../RockyLinux_9.4_VMM.7z/download",
  "fileName": "RockyLinux_9.4_VMM.7z",
  "md5": "9146197b09929b21e93fd5b830eba0eb",
  "sha1": "09532ab8a3f8b7a1c969841f2d8ca0a5ec2145ee",
  "guestId": "rhel9_64Guest",
  "firmware": "bios",
  "diskSize": 40,
  "templateName": "TEMPLATE-LINUX-ROCKYLINUX-9-MINIMAL"
}
```

| Field | Meaning |
|---|---|
| `os` | One of `centos`, `rockylinux`, `almalinux`, `ubuntu`, `debian`, `windows`. |
| `version` | The value used in `machines/*.json`, e.g. `9`, `24.04`, `2022`. |
| `variant` | `minimal` / `graphical` for most distros, `default` for Ubuntu, `standard` for Windows. Omitted in a machine JSON means `default`. |
| `release` | Human-readable upstream release; documentation only. |
| `kind` | `linux` (auto-downloaded) or `windows` (template you maintain). |
| `sourcePage`, `downloadUrl`, `fileName`, `md5`, `sha1` | Linux only. Published by LinuxVMImages. |
| `guestId`, `firmware`, `diskSize` | Defaults applied by Terraform when cloning. `diskSize` is in GB. |
| `templateName` | Name of the vCenter template to clone. The preparation script registers Linux templates with exactly this name. |

`defaults.templateFolder` is the vCenter VM folder that holds all templates
(`TerraformTemplates` by default).

## Available images

| os | versions | variants | Upstream source |
|---|---|---|---|
| `rockylinux` | `9` (9.4), `10` (10.1), `8` (8.10) | minimal, graphical | linuxvmimages.com |
| `centos` | `9` (Stream 9), `8` (Stream 8) | minimal, graphical | linuxvmimages.com |
| `almalinux` | `9` (9.0) | minimal, graphical | linuxvmimages.com |
| `ubuntu` | `24.04`, `22.04` | default | linuxvmimages.com |
| `debian` | `12` (12.0.0) | minimal, graphical | linuxvmimages.com |
| `windows` | `2019`, `2022`, `2025` | standard | Your own vCenter template |

Linux catalog entries were captured from the CHECKSUM tabs of the detail pages
linked from <https://www.linuxvmimages.com/images/vmware/>. Checksums are the
**published MD5 and SHA-1** of the exact 7z archives; the site does not publish
SHA-256.

## Verification policy

The preparation script implements this policy:

1. If the archive is not cached, download it from `downloadUrl` and reject
   anything that is not a 7z file (magic bytes `37 7A BC AF 27 1C`).
2. If a `<archive>.sha256` sidecar exists **and** matches the locally computed
   SHA-256, trust the cached file and skip MD5/SHA-1 (fast path). The sidecar is
   only ever written after a successful MD5/SHA-1 verification.
3. Otherwise compute MD5 and SHA-1 and compare them with the catalog. A
   mismatch deletes the archive and fails the run.
4. On success, write the local SHA-256 sidecar.

This means the published values are always pinned, while repeated runs avoid
re-hashing large archives. Never edit a catalog `md5`/`sha1` to make a failed
verification pass — re-check the upstream CHECKSUM tab instead.

## Windows templates

LinuxVMImages has no Windows images, and Windows media cannot be redistributed
here. Create a Windows VM in vCenter, install the OS and VMware Tools, sysprep
it, and mark it as a template named to match `templateName` in the catalog
(e.g. `TEMPLATE-WINDOWS-2022-STANDARD`). `prepare-vm-images.ps1` checks that the
template exists but never downloads or modifies it. Set
`TF_VAR_windows_admin_password` so Terraform can sysprep the clones.

## Adding or updating an image

1. Open the detail page on linuxvmimages.com and pick the **REGULAR DOWNLOAD /
   SourceForge** VMware link for the variant you want.
2. Copy the URL, file name, MD5 and SHA-1 from that page into a new catalog
   entry. Keep `version` stable so existing machine JSON files keep working;
   change `release`, URL and checksums when a newer upstream build is published.
3. Give the template a new `templateName` when the disk content changes, so the
   script registers a fresh template instead of reusing the old one.
4. Run `scripts/prepare-vm-images.ps1 -All -DryRun` to check the catalog, then
   run the image pipeline (or the script without `-DryRun`) to register it.
5. Update `machines/*.json` to the new `version`/`variant` and run the Plan
   pipeline to review the clone replacement.

Firmware is inherited from the template when cloning; the catalog `firmware`
value is documentation only. Guest IDs must be supported by your vSphere
version — for example older vCenter releases do not have a RHEL 10 guest ID, so
Rocky Linux 10 uses `rhel9_64Guest`.
