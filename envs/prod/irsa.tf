# Both roles use terraform-aws-modules/iam/aws's IRSA submodule, which wires
# up the OIDC trust policy condition (service account namespace + name)
# correctly — the part that's easy to get subtly wrong by hand.

# Brief requirement: EBS CSI driver needs IAM permissions to create/attach
# EBS volumes on behalf of PersistentVolumeClaims. Referenced by
# aws-ebs-csi-driver in addons.tf.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name             = "${var.cluster_name}-ebs-csi-driver"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# The role only — Milestone 5 installs the aws-load-balancer-controller
# chart itself and passes this ARN in as a value. Created here because only
# the AWS owner can create IAM roles, and M5 shouldn't be blocked on that.
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name                              = "${var.cluster_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# Milestone 7 — External Secrets Operator reads exactly one secret
# (aws_secretsmanager_secret.app, defined in secrets.tf) and nothing else.
#
# module.iam-role-for-service-accounts-eks's attach_external_secrets_policy
# flag exists but is deliberately NOT used: its canned policy
# (policies.tf:586 in that module) grants ssm:DescribeParameters on "*" and
# secretsmanager:ListSecrets + BatchGetSecretValue on "*" — account-wide
# secret enumeration this project has no use for (it reads Secrets Manager
# only, never Parameter Store, and never in batch). A hand-written policy on
# one ARN costs nothing extra and removes that blast radius.
#
# No kms:Decrypt: the secret uses the AWS-managed aws/secretsmanager key,
# which Secrets Manager decrypts with on the caller's behalf. A
# customer-managed key would need it; this project doesn't use one.
resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets"
  description = "Read-only access to the one Secrets Manager secret ESO syncs into the cluster."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = aws_secretsmanager_secret.app.arn
    }]
  })
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name = "${var.cluster_name}-external-secrets"

  # serviceAccount.name is pinned to "external-secrets" in the Helm values
  # (argocd/applications/10-external-secrets.yaml) — the trust condition
  # below must match that exact name, or AssumeRoleWithWebIdentity fails
  # with AccessDenied that surfaces only as SecretSyncedError in a
  # controller log, not here.
  role_policy_arns = {
    read = aws_iam_policy.external_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}
