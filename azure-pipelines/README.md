# Azure DevOps pipelines

For GitHub Actions equivalents, see [`github-actions/`](../github-actions/README.md).
Both sets drive the same Terraform code and JSON files.

| File | Purpose |
|---|---|
| `create.yml` | **Create / apply** — plans and applies the selected cluster from its JSON files. |
| `delete.yml` | **Delete** — plans a destroy and applies that saved plan. Requires `confirmDelete = true`. |
| `plan.yml` | **Plan** — plans only, and publishes the saved plan as a build artifact. |
| `drift.yml` | **Drift detection** — nightly `plan -detailed-exitcode`; fails when vSphere differs from the committed configuration. |
| `import.yml` | **Import** — adopt an existing cluster, VDS, port groups and VMs into that cluster's state; reads the `imports/*.json` object paths. |
| `images.yml` | **Images** — download, MD5/SHA-1 verify and register the Linux OS templates used by a cluster; only checks that Windows templates exist. Supports `all` and `dryRun`. |
| `templates/terraform-init.yml` | Shared setup: generates the Git-ignored `globals.json` / `backend.tf`, then runs `terraform init` for AWS or Azure. |

All six pipelines run on `ubuntu-latest`. The five Terraform pipelines target
one cluster folder at a time (parameter `clusterName`), and support either
backend (parameter `cloud: aws | azure`). They are manual by default; only
`drift.yml` has a schedule. `images.yml` does not use the Terraform backend; it
installs `govc` and `p7zip-full`, then runs
`scripts/prepare-vm-images.ps1`. Run it once before Plan/Create when machines
select an OS.

## One-time setup

### 1. Create the variable group `terraform-backend`

Add these variables. Mark the ones noted **secret** as secret.

| Variable | Secret | Example / notes |
|---|---|---|
| `VSPHERE_SERVER` | no | `vcenter.example.local` |
| `VSPHERE_USER` | no | `terraform@vsphere.local` |
| `TF_VAR_vsphere_password` | **yes** | vCenter password. The `TF_VAR_` prefix is required. |
| `TF_VAR_windows_admin_password` | **yes** | Local administrator password for Windows sysprep; required only when cloning Windows templates. |
| `ALLOW_UNVERIFIED_SSL` | no | `false` (or `true` for self-signed certs) |
| `DATACENTER_NAME` | no | `DC01` |
| `DATASTORE_NAME` | no | `DS-VM-01` |
| `ISO_DATASTORE_NAME` | no | `DS-ISO-01`; leave **empty** if no VM uses an ISO |
| `AWS_BUCKET` | no | Terraform state bucket |
| `AWS_REGION` | no | e.g. `eu-west-1` |
| `AWS_LOCK_TABLE` | no | DynamoDB lock table |
| `AWS_KEY_PREFIX` | no | e.g. `vsphere` |
| `AWS_ACCESS_KEY_ID` | **yes** | Used by the S3 backend |
| `AWS_SECRET_ACCESS_KEY` | **yes** | Used by the S3 backend |
| `AZURE_RESOURCE_GROUP` | no | State resource group |
| `AZURE_STORAGE_ACCOUNT` | no | State storage account |
| `AZURE_CONTAINER` | no | State blob container |
| `AZURE_KEY_PREFIX` | no | e.g. `tfstate` |
| `ARM_CLIENT_ID` | no | Service principal |
| `ARM_TENANT_ID` | no | Service principal |
| `ARM_SUBSCRIPTION_ID` | no | Service principal |
| `ARM_CLIENT_SECRET` | **yes** | Service principal secret |

Link the group to each pipeline (already declared via `variables: - group:
terraform-backend`). For production, prefer workload identity federation or
managed identities over a client secret, and grant the service principal
**Storage Blob Data Contributor** on the state container.

### 2. Create the pipelines in Azure DevOps

`New pipeline → Azure Repos Git → Existing YAML file`, then pick the file:

```
/azure-pipelines/create.yml
/azure-pipelines/delete.yml
/azure-pipelines/plan.yml
/azure-pipelines/drift.yml
/azure-pipelines/import.yml
/azure-pipelines/images.yml
```

Name them e.g. `Terraform - Create`, `Terraform - Delete`, etc.

### 3. Recommended: add an approval gate

In `create.yml` and `delete.yml`, create an environment (e.g. `vSphere`), add
the required approvers/checks, and uncomment:

```yaml
environment: vSphere
```

### 4. Branch for drift detection

`drift.yml` watches `main`. If your default branch differs, edit the `branches:
include:` list. The schedule runs at 03:00 UTC daily with `always: true`, so it
also runs when there were no source changes.

## Running a pipeline

Every pipeline prompts for:

- `clusterName` — folder under `clusters/`, e.g. `CLUSTER-PROD-01`
- `cloud` — `aws` or `azure`

`delete.yml` additionally requires `confirmDelete = true`.

`import.yml` additionally exposes `importCluster`, `importNetworks`, `importVms`
(all default `true`) and `dryRun` (default `false`).

Each run generates `globals.json` and `backend.tf` from the variable group, so
the pipelines work without any Git-ignored files being committed. State keys are
per cluster:

- AWS: `<AWS_KEY_PREFIX>/<clusterName>/terraform.tfstate`
- Azure: `<AZURE_KEY_PREFIX>/<clusterName>.tfstate`

## Importing existing infrastructure

`import.yml` adopts objects that already exist in vCenter into the cluster's
state, so you can manage them with Terraform afterwards. It does not create or
change anything in vSphere — it only writes state.

### Define the object paths first

Each cluster folder has an `imports/` directory with one file per resource
group. These hold the **real vCenter inventory paths**, which can differ from
the logical names in `networks/*.json` and `machines/*.json`:

| File | Maps to |
|---|---|
| `imports/cluster.json` | `vsphere_compute_cluster.this` |
| `imports/networks.json` | `vsphere_distributed_virtual_switch.this[0]` and `vsphere_distributed_port_group.this["<name>"]` |
| `imports/machines.json` | `vsphere_virtual_machine.machine["<name>"]` |

Example (`imports/cluster.json`):

```json
{
  "resource": "vsphere_compute_cluster.this",
  "path": "/{datacenter}/host/Compute/CLUSTER-PROD-01"
}
```

`{datacenter}` is replaced with `DATACENTER_NAME` from the variable group at
runtime. A fully literal path also works, e.g.
`/DC01/vm/Production/prod-app-01` — useful when VMs live inside VM folders.
Include host folders in the cluster path and VM folders in the VM path.

vSAN is **not** a separate import: disk groups, fault domains, stretched cluster
and DIT encryption are properties of `vsphere_compute_cluster.this`, so they are
adopted with the cluster. `imports/networks.json` is ignored when `cluster.json`
has `create_networks: false` (those networks are data sources).

### Behaviour

- **Idempotent** — addresses already in state are skipped, so the pipeline can be
  re-run safely after a partial failure.
- **Non-fatal failures** — a bad path logs a pipeline warning and the loop
  continues with the remaining objects. Check the log for `##vso` warnings.
- **`dryRun: true`** — prints `WOULD IMPORT: <address> <- <path>` for every object
  without changing state. Use this to verify paths first.
- A missing `imports/` directory fails the job with an error; missing individual
  files produce warnings and skip that resource group.
- After importing, `terraform state list` is printed and a `terraform plan` runs.
  Expect drift: reconcile `cluster.json`, `networks/*.json` and `machines/*.json`
  with the imported state before running `create.yml`.

Typical order: run with `dryRun: true`, fix paths, run for real, then update the
config JSON until the post-import plan is clean.

## Notes

- A saved plan from `plan.yml` is **not** reusable by `create.yml` — it is bound
  to that run's state and configuration. `create.yml` always creates its own
  saved plan. The artifact is for audit only.
- `delete.yml` prints a destroy plan in the logs before applying it. Review that
  output before the apply step runs, or add an environment approval between the
  two steps.
- Drift detection fails on both real drift (exit 2) and plan errors (exit 1).
  Fix configuration drift by re-running `create.yml` or by updating the JSON
  files to match reality.
