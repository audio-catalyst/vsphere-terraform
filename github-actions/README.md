# GitHub Actions workflows

These are the GitHub Actions equivalents of the Azure DevOps pipelines in
`azure-pipelines/`. Both sets drive the same Terraform code and JSON files.

## Canonical sources vs. what GitHub runs

GitHub only discovers workflows in `.github/workflows/` and composite actions in
`.github/actions/`. The editable sources live here:

```
github-actions/
├── create.yml
├── delete.yml
├── plan.yml
├── drift.yml
├── import.yml
├── images.yml                  <- prepare/verify OS templates
├── terraform-init/action.yml   <- shared composite action
└── README.md
```

After editing anything in this folder, mirror it into place:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync-github-workflows.ps1
```

That copies:

- `github-actions/*.yml` → `.github/workflows/`
- `github-actions/terraform-init/action.yml` → `.github/actions/terraform-init/action.yml`

The copies in `.github/` are generated. Commit both the source and the mirror;
GitHub will ignore the `github-actions/` folder itself.

## Workflows

| File | Purpose |
|---|---|
| `create.yml` | **Create / apply** — plans and applies the selected cluster. |
| `delete.yml` | **Delete** — destroy plan then apply; requires `confirmDelete = true`. |
| `plan.yml` | **Plan** — plans only and uploads the saved plan as an artifact. |
| `drift.yml` | **Drift detection** — nightly `plan -detailed-exitcode`; fails on drift or plan errors. |
| `import.yml` | **Import** — adopts existing objects using the per-cluster `imports/*.json` paths. |
| `images.yml` | **Images** — downloads, MD5/SHA-1 verifies and registers Linux OS templates; only checks that Windows templates exist. Supports `all` and `dryRun`. |
| `terraform-init/action.yml` | Shared setup: generates `globals.json` / `backend.tf`, then `terraform init`. |

All workflows run on `ubuntu-latest` and use `actions/checkout@v4`. The five
Terraform workflows also use `hashicorp/setup-terraform@v3` and take
`clusterName` plus `cloud` (`aws` | `azure`) as `workflow_dispatch` inputs.
Import additionally exposes `importCluster`, `importNetworks`, `importVms` and
`dryRun`. `images.yml` installs `p7zip-full` and `govc` instead of Terraform and
exposes `all`, `dryRun` and `templateHost`. Run it once before Plan/Create when
machines select an OS.

## One-time setup

Azure DevOps variable groups have no direct GitHub equivalent. Create
**repository variables** (Settings → Secrets and variables → Actions →
Variables) and **repository secrets** for the values below. Use environment
variables or organization-level values if you prefer.

### Repository variables

| Variable | Example / notes |
|---|---|
| `VSPHERE_SERVER` | `vcenter.example.local` |
| `VSPHERE_USER` | `terraform@vsphere.local` |
| `ALLOW_UNVERIFIED_SSL` | `false` (or `true` for self-signed certs) |
| `DATACENTER_NAME` | `DC01` |
| `DATASTORE_NAME` | `DS-VM-01` |
| `ISO_DATASTORE_NAME` | `DS-ISO-01`; leave **empty** if no VM uses an ISO |
| `AWS_BUCKET` | Terraform state bucket |
| `AWS_REGION` | e.g. `eu-west-1` |
| `AWS_LOCK_TABLE` | DynamoDB lock table |
| `AWS_KEY_PREFIX` | e.g. `vsphere` |
| `AZURE_RESOURCE_GROUP` | State resource group |
| `AZURE_STORAGE_ACCOUNT` | State storage account |
| `AZURE_CONTAINER` | State blob container |
| `AZURE_KEY_PREFIX` | e.g. `tfstate` |
| `ARM_CLIENT_ID` | Service principal |
| `ARM_TENANT_ID` | Service principal |
| `ARM_SUBSCRIPTION_ID` | Service principal |

### Repository secrets

| Secret | Notes |
|---|---|
| `TF_VAR_vsphere_password` | vCenter password. The `TF_VAR_` prefix is required by the root module. |
| `TF_VAR_windows_admin_password` | Local administrator password for Windows sysprep; required only when cloning Windows templates. |
| `AWS_ACCESS_KEY_ID` | Used by the S3 backend. |
| `AWS_SECRET_ACCESS_KEY` | Used by the S3 backend. |
| `ARM_CLIENT_SECRET` | Service principal secret. Prefer workload identity federation in production. |

The workflows map these into step-level `env`, so no Terraform variable file is
committed. The composite action generates `globals.json` and `backend.tf` at
runtime using `${{ github.workspace }}`; both files are Git-ignored.

## Recommended hardening

- Uncomment `environment: vSphere` in `create.yml` and `delete.yml`, create that
  environment in Settings → Environments, and add required reviewers.
- Keep `permissions: contents: read` as declared. Only `actions/upload-artifact`
  needs extra scope on some hardened repositories.
- `drift.yml` runs at 03:00 UTC. Scheduled workflows only run on the default
  branch, so commit the mirrored files there. GitHub does not populate
  `workflow_dispatch` defaults on scheduled runs, so that workflow uses
  `${{ inputs.clusterName || 'CLUSTER-PROD-01' }}` and
  `${{ inputs.cloud || 'aws' }}` fallbacks. Change those fallback literals (in
  every occurrence) if your primary cluster or backend differs, or add a
  second scheduled workflow for another cluster.

## Import notes

`import.yml` reads `clusters/<CLUSTER>/imports/cluster.json`,
`imports/networks.json` and `imports/machines.json`. It skips addresses already
in state, logs warnings for bad paths, supports `dryRun: true`, and runs a
post-import plan. vSAN is imported together with the compute cluster — there is
no separate vSAN resource. See the root `README.md` for the JSON format.
