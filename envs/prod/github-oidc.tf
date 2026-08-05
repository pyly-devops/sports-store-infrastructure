# Trusts GitHub Actions' OIDC tokens, for Milestone 6's per-repo CI
# workflows to assume a push role without ever holding a static AWS key
# (CLAUDE.md non-negotiable).
#
# Looked up, not created: AWS allows exactly one OIDC provider per URL per
# account, and this account already has one for
# token.actions.githubusercontent.com from unrelated work that predates this
# project. A `resource` here would fail on apply with EntityAlreadyExists.
# Every account should only ever have one of these — any number of roles can
# trust the same provider, so referencing it is the correct shape even in an
# account with no pre-existing conflict, not just a workaround for this one.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
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
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
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

# The gateway is the only component whose build CONSUMES another component's
# image: its Dockerfile does `FROM ${FRONTEND_IMAGE}`, pointing at
# sports-store/frontend. That is a pull, and the shared ecr-push policy above
# scopes every action to the role's OWN repository — correctly, and this is the
# single documented exception rather than a hole punched in the general rule.
#
# Pull only. The gateway role still cannot push to sports-store/frontend, so a
# compromised gateway workflow can read the bundle it already bakes into its own
# image and can do nothing else with it.
data "aws_iam_policy_document" "gateway_frontend_pull" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.app["sports-store-frontend"].arn]
  }
}

resource "aws_iam_role_policy" "gateway_frontend_pull" {
  name   = "ecr-pull-frontend"
  role   = aws_iam_role.github_actions_push["sports-store-gateway"].id
  policy = data.aws_iam_policy_document.gateway_frontend_pull.json
}
