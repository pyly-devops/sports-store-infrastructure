# Milestone 7 — the one secret External Secrets Operator syncs into the
# cluster. JWT_SECRET + Mongo root credentials, one copy, read by two
# ExternalSecrets (app-secrets, mongodb-credentials) so there is nowhere for
# them to drift from. See sports-store-deployments/argocd/README.md.
#
# Deliberately no aws_secretsmanager_secret_version resource here.
#
# A version resource puts the plaintext value into tfstate, and "no secrets
# in git or state" (CLAUDE.md) gets no exemption for tfstate. Consequence
# accepted: `terraform plan` has no opinion about the value and never shows
# drift when it rotates outside Terraform, and a fresh apply produces an
# EMPTY secret — ESO reports SecretSyncedError with
# ResourceNotFoundException until the bootstrap runbook's step 2
# (`aws secretsmanager put-secret-value`) runs by hand. That is a loud,
# correct failure, not a silent one.
resource "aws_secretsmanager_secret" "app" {
  name = "sports-store/prod/app"

  # AWS infra here is ephemeral (CLAUDE.md) — destroy must be provably
  # re-appliable. With a recovery window, destroy only *schedules* deletion
  # and holds the name, so the next apply fails with "a secret with this
  # name is already scheduled for deletion." Wrong for real production,
  # correct for a project that gets destroyed and re-applied routinely.
  # Consequence: the value is gone after every destroy; runbook step 2 must
  # be re-run.
  recovery_window_in_days = 0
}
