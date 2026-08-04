# sports-store-infrastructure

Terraform for the CloudCart AWS foundation: VPC, EKS, ECR, and the IAM that
later milestones authenticate as. Built on public modules
(`terraform-aws-modules/vpc/aws`, `terraform-aws-modules/eks/aws`) — no
hand-rolled networking or cluster resources.

Part of the [CloudCart](https://github.com/pyly-devops) polyrepo — see
[sports-store-deployments](https://github.com/pyly-devops/sports-store-deployments)
for how this fits into the overall system.

## Layout

```text
bootstrap/          # run ONCE, locally, by the AWS owner — creates the IAM
                     # role HCP Terraform assumes to run envs/prod
envs/prod/           # the VCS-driven HCP Terraform workspace (working
                     # directory = envs/prod). Everything else lives here.
```

Two root modules, not one: `bootstrap/` creates the credential `envs/prod`
authenticates with, so it cannot live in the same state — the first run would
have no way to authenticate.

There is no `modules/` directory. Every resource here is either a public
module call or a handful of IAM documents that a local module would only
obscure.

## Why only one person can apply

One AWS account, one person with credentials to it (`CLAUDE.md`
non-negotiable). Everyone else contributes by opening a PR — HCP Terraform
posts a **speculative plan** on the PR, which is what gets reviewed and
approved. Applies (`bootstrap/` and `envs/prod`) are run by the AWS owner only,
manual confirmation required, never on auto-apply.

## HCP Terraform setup

Org `pyly-devops`, two workspaces:

| Workspace | Type | Working dir | Notes |
| --- | --- | --- | --- |
| `sports-store-bootstrap` | CLI-driven, local execution | `bootstrap/` | Owner runs `terraform login` + `terraform init`/`apply` locally with their own AWS credentials. |
| `sports-store-prod` | VCS-driven, linked to this repo | `envs/prod` | Auto-apply off. Env vars `TFC_AWS_PROVIDER_AUTH=true` and `TFC_AWS_RUN_ROLE_ARN=<bootstrap output>` (set after the bootstrap apply). |

No AWS keys are stored in HCP anywhere — both workspaces authenticate via
OIDC dynamic credentials.

## Getting `kubectl` access

Only the AWS owner's IAM principal has a cluster access entry
(`AmazonEKSClusterAdminPolicy`) — see `envs/prod/eks.tf`. Once the cluster
exists:

```text
aws eks update-kubeconfig --region us-east-1 --name <cluster_name output>
kubectl get nodes
```

Everyone else reaches the cluster through Argo CD (Milestone 7) and Grafana
(Milestone 8), not `kubectl` — a deliberate GitOps posture, not a workaround.

## Branching

- `feature/*` — new work
- `bugfix/*` — non-urgent fixes
- `hotfix/*` — urgent production fixes

`main` is protected: all changes land via pull request with at least one
approval (`enforce_admins` is on — nobody, including org owners, pushes
straight to `main`).

## Development

```text
terraform fmt -check -recursive
terraform validate            # in bootstrap/ and envs/prod, after `terraform init`
```

`terraform plan` runs automatically as a speculative plan when a PR is opened
against `envs/prod`. `terraform apply` is never run in CI — only by the AWS
owner, locally or via a manually confirmed HCP run, since it provisions real
billed AWS resources.

## CI/CD

No GitHub Actions workflow in this repo yet. `terraform fmt`/`validate`
linting on PRs is a candidate; state changes are entirely HCP Terraform's
job, not this repo's CI.
