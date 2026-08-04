# Trusts HCP Terraform's workload identity tokens. AWS stopped validating the
# thumbprint against a fixed value in 2022 (it now checks the TLS chain
# directly), but the field is still required at creation time, so it's
# fetched live rather than hardcoded — a hardcoded value would go stale
# silently if app.terraform.io ever rotated its certificate.
data "tls_certificate" "hcp_terraform" {
  url = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "hcp_terraform" {
  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.hcp_terraform.certificates[0].sha1_fingerprint]
}

# Scoped to exactly one workspace's runs, not the whole HCP org — without
# this, any workspace in pyly-devops could assume the role that provisions
# the entire AWS account.
data "aws_iam_policy_document" "run_role_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.hcp_terraform.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "app.terraform.io:aud"
      values   = ["aws.workload.identity"]
    }

    condition {
      test     = "StringLike"
      variable = "app.terraform.io:sub"
      values = [
        "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${var.hcp_prod_workspace}:run_phase:*"
      ]
    }
  }
}

resource "aws_iam_role" "run_role" {
  name               = "hcp-terraform-sports-store-prod-run-role"
  assume_role_policy = data.aws_iam_policy_document.run_role_trust.json
}

# AdministratorAccess is the honest starting point: envs/prod creates IAM
# roles, an OIDC provider, VPC, EKS and ECR resources across the account, and
# a hand-written least-privilege policy would be a moving target that breaks
# every plan as new resource types get added. The mitigation that actually
# applies is the trust condition above, not this policy: the role is only
# assumable by the sports-store-prod workspace, whose applies require the AWS
# owner's manual confirmation in HCP. Nobody else can trigger a run that uses
# this role, regardless of what the attached policy allows.
resource "aws_iam_role_policy_attachment" "run_role_admin" {
  role       = aws_iam_role.run_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
