# Trusts GitHub Actions' OIDC tokens, for Milestone 6's per-repo CI
# workflows to assume a push role without ever holding a static AWS key
# (CLAUDE.md non-negotiable).
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# One role per app repo, for_each over the same var.app_components map
# ecr.tf uses — same 7 components, guaranteed to match.
data "aws_iam_policy_document" "github_actions_trust" {
  for_each = var.app_components

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restricted to refs/heads/main, not a wildcard — this is what actually
    # enforces "PRs never publish an image", not workflow discipline. A PR
    # run's token has sub = repo:.../pull/<n>, which never matches, so it
    # cannot assume the role at all.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${each.key}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_push" {
  for_each = var.app_components

  name               = "github-actions-${each.key}-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust[each.key].json
}

# ecr:GetAuthorizationToken has no resource-level form — it's account-scoped
# by nature, so it's granted on "*" rather than left off (leaving it off
# would just make docker login fail, not add any real restriction). Push/
# pull actions are scoped to that one repo's ARN: a compromised
# catalog-service workflow gets a role that flatly cannot touch the
# payment-service image.
data "aws_iam_policy_document" "github_actions_push" {
  for_each = var.app_components

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.app[each.key].arn]
  }
}

resource "aws_iam_role_policy" "github_actions_push" {
  for_each = var.app_components

  name   = "ecr-push"
  role   = aws_iam_role.github_actions_push[each.key].id
  policy = data.aws_iam_policy_document.github_actions_push[each.key].json
}
