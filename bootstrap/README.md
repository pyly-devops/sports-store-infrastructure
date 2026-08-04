# bootstrap/

Run once, locally, by the AWS owner. Creates the IAM OIDC provider and run
role that the `sports-store-prod` HCP Terraform workspace (`envs/prod`) uses
to authenticate to AWS. Without this, `envs/prod` has no credential at all —
HCP Terraform never holds a static AWS access key.

This module's own state is remote (HCP Terraform, workspace
`sports-store-bootstrap`, CLI-driven, local execution) so it satisfies the
"state is never local" rule too, without creating a chicken-and-egg problem:
it authenticates with the AWS owner's own long-lived credentials, not the
role it creates.

## One-time procedure

1. **Create the HCP org and this workspace**, if they don't exist yet: org
   `pyly-devops` at [app.terraform.io](https://app.terraform.io). The
   `sports-store-bootstrap` workspace is created automatically on first
   `terraform init` below — no need to click it into existence first.

2. **Authenticate the CLI to HCP Terraform:**

   ```text
   terraform login
   ```

3. **Authenticate to AWS** with the owner's own credentials (SSO, access
   keys in env vars, whatever is normally used) — this run does NOT use
   OIDC, since the role it needs doesn't exist yet.

4. **Init and apply:**

   ```text
   cd bootstrap
   terraform init
   terraform plan
   terraform apply
   ```

5. **Copy the `run_role_arn` output.** In the HCP Terraform UI, open the
   `sports-store-prod` workspace → Variables → add two environment variables:

   | Key | Value |
   | --- | --- |
   | `TFC_AWS_PROVIDER_AUTH` | `true` |
   | `TFC_AWS_RUN_ROLE_ARN` | the `run_role_arn` output from step 4 |

   Neither is sensitive — the ARN alone can't authenticate as anything; only
   the workspace named in the trust policy's `sub` condition can assume it.

## When to re-run

Only if the trust policy needs to change (workspace renamed, project
renamed) or the run role's permissions need adjusting. Routine `envs/prod`
work never touches this module.
