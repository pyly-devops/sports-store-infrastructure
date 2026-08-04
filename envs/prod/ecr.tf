# One repo per component, for_each over var.app_components (defined in
# variables.tf) so this and github-oidc.tf can never iterate a different set
# of 7 components from each other.
#
# 7 repos, not 6 — the gateway image builds the React bundle from a sibling
# checkout, which doesn't exist in CI. The resolution (frontend publishes its
# own build output as an image, gateway pulls it) is Milestone 5/6 work, but
# creating the repo now costs nothing and removes that blocker later.
resource "aws_ecr_repository" "app" {
  for_each = var.app_components

  name = "sports-store/${each.value}"

  # Tags are <semver>-<7-char-git-hash> (CLAUDE.md non-negotiable) and are
  # never supposed to move. IMMUTABLE makes that enforced by ECR itself
  # instead of aspirational.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Ephemeral infra: destroy needs to work without manually emptying every
  # repo of pushed images first. Intentionally destructive — fine here,
  # would not be fine on a real production registry.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = {
        type = "expire"
      }
    }]
  })
}
