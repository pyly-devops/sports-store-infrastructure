# ---------------------------------------------------------------------------
# S3 + CloudFront — static/dynamic split (Milestone 9).
#
# WHY ONE DISTRIBUTION WITH TWO ORIGINS, AND NOT A SEPARATE STATIC SITE:
#
# sports-store-frontend/src/api.js calls the API ROOT-RELATIVE:
#
#     const response = await fetch(`/api${path}`, { ...options, headers })
#
# The browser therefore sends every API call to whatever origin served the
# page. If CloudFront serves the SPA, CloudFront MUST also serve /api/* or
# every API call 404s at the edge. That single line of JavaScript is what
# fixes the shape of everything below.
#
# The same file sets `Authorization: Bearer <token>` from localStorage, which
# is why the /api/* behaviour needs an explicit origin request policy — see
# the ordered_cache_behavior block.
#
# WHAT THIS DOES AND DOES NOT CHANGE:
#
# The gateway keeps its baked-in frontend bundle. CloudFront is purely
# additive. The static/dynamic split is still fully achieved — browsers stop
# fetching JS/CSS from the gateway — while the ALB health check
# (healthcheck-path: /, which serves index.html off the gateway's own disk),
# the M7 frontend->gateway dispatch chain, and a working direct-ALB fallback
# URL all keep working untouched.
#
# Expect one visible side effect in Milestone 8's Loki dashboards: gateway
# access logs now show API traffic only, because static requests never reach
# nginx. That is an improvement, not a regression.
# ---------------------------------------------------------------------------

# --- The chicken-and-egg, and the flag that solves it ----------------------
#
# TERRAFORM DOES NOT CREATE THE ALB. The AWS Load Balancer Controller does,
# from the Helm chart's Ingress, long after this workspace has finished
# applying. So there is no resource attribute to point a CloudFront origin at
# — only a data source lookup, which fails outright when no cluster exists.
#
# With enable_cloudfront = false (the default) the data source is never
# evaluated and none of this file's resources are created, so `terraform
# apply` from zero still works exactly as Milestone 4 proved. Once the
# cluster is up and the Ingress has produced an ALB, flip the flag and apply
# again. Two-phase by design, not by accident.

data "aws_lb" "ingress" {
  count = var.enable_cloudfront ? 1 : 0

  # Both tags, not just the cluster one. The Load Balancer Controller stamps
  # elbv2.k8s.aws/cluster on every load balancer it manages in this cluster,
  # which would also match a second Ingress if anyone ever adds one; the
  # stack tag pins this to the single `gateway` Ingress in the sports-store
  # namespace (helm/sports-store/templates/ingress.yaml). A data source that
  # matches two load balancers is an error, so being specific here turns a
  # future ambiguity into a non-event.
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "sports-store/gateway"
  }
}

# AWS-managed policies, looked up by name. Not count-guarded: they always
# exist in every account, cost nothing, and are far more readable referenced
# directly than through a [0]. The aws_lb lookup above is guarded because
# that one genuinely fails when the cluster is gone.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# --- The bucket ------------------------------------------------------------

resource "aws_s3_bucket" "frontend" {
  count = var.enable_cloudfront ? 1 : 0

  bucket = "sports-store-frontend-${data.aws_caller_identity.current.account_id}"

  # Same reasoning as cloudtrail.tf: S3 will not delete a bucket containing
  # objects, and CI puts a bundle in here on every merge to main. Without
  # this, `terraform destroy` — proven working since Milestone 4 — starts
  # failing and someone has to empty the bucket by hand first.
  force_destroy = true
}

# The bucket is private. Nothing reads it directly; CloudFront reads it via
# the Origin Access Control below, with a bucket policy that names the one
# distribution allowed. Public read on the bucket would also work and is what
# most tutorials do — it just means the S3 URL is a second, uncached,
# unprotected way into the same content.
resource "aws_s3_bucket_public_access_block" "frontend" {
  count = var.enable_cloudfront ? 1 : 0

  bucket = aws_s3_bucket.frontend[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  count = var.enable_cloudfront ? 1 : 0

  bucket = aws_s3_bucket.frontend[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# OAC, not the legacy OAI. OAI still works but AWS has stopped developing it;
# OAC signs with SigV4 and is the only one of the two that supports SSE-KMS
# buckets, so it is what a new distribution should use even when — as here —
# the bucket is SSE-S3 and either would do.
resource "aws_cloudfront_origin_access_control" "frontend" {
  count = var.enable_cloudfront ? 1 : 0

  name                              = "sports-store-frontend"
  description                       = "Lets only the sports-store distribution read the private frontend bucket."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- SPA routing -----------------------------------------------------------
#
# ⚠️ THE MISTAKE THIS AVOIDS, WRITTEN OUT BECAUSE IT LOOKS LIKE THE RIGHT
#    ANSWER AND IS NOT:
#
# The standard recipe for an SPA on CloudFront is a pair of
# `custom_error_response` blocks mapping 403 and 404 to /index.html with a
# 200. It works, and on a distribution that also serves an API it silently
# corrupts data.
#
# custom_error_response is configured PER DISTRIBUTION, not per cache
# behaviour. It applies to the /api/* behaviour too. The five FastAPI
# services return 404 in ten places and 403 in five (grep for status_code=),
# so "product not found" would leave the ALB as a 404 and arrive at the
# browser as 200 OK with an HTML body. api.js checks `response.ok`, which
# would be true, then returns a null body instead of throwing — a missing
# product would render as an empty page rather than an error, and a
# forbidden request would look like a successful one.
#
# A CloudFront Function attached to a single cache behaviour is the fix.
# /api/* never invokes it and keeps its real status codes.
#
# COST: CloudFront Functions are in the always-free tier at 2,000,000
# invocations/month, then $0.10/million. Only static requests invoke this
# one. At demo scale it is free.
resource "aws_cloudfront_function" "spa_router" {
  count = var.enable_cloudfront ? 1 : 0

  name    = "sports-store-spa-router"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrites extensionless paths to /index.html for React Router. Default behaviour only."
  code    = file("${path.module}/cloudfront-spa-router.js")
  publish = true
}

# --- The distribution ------------------------------------------------------

resource "aws_cloudfront_distribution" "main" {
  count = var.enable_cloudfront ? 1 : 0

  enabled         = true
  is_ipv6_enabled = true
  comment         = "sports-store — SPA from S3, /api/* to the ALB"

  # Handles a request for "/" before the function sees it. The function
  # covers it too; both are cheap and neither is load-bearing alone.
  default_root_object = "index.html"

  # US/EU edge locations only — the cheapest tier, and every viewer of this
  # project is in one of those regions. PriceClass_All would add Asia-Pacific
  # and South America edges at a higher per-request rate for no benefit here.
  price_class = "PriceClass_100"

  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend[0].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend[0].id
  }

  origin {
    origin_id   = "alb-api"
    domain_name = data.aws_lb.ingress[0].dns_name

    custom_origin_config {
      http_port  = 80
      https_port = 443

      # http-only, and this is a real limitation stated plainly rather than
      # hidden: the ALB has no certificate because the project owns no
      # domain, so there is nothing for CloudFront to validate against.
      # Viewer -> CloudFront is HTTPS; CloudFront -> ALB is HTTP inside AWS's
      # network. Consistent with the same decision already recorded in
      # Milestone 5's ingress annotations. Fixing it properly means Route 53
      # + ACM, which is a different milestone.
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # --- Static: everything that is not /api/* -------------------------------
  default_cache_behavior {
    target_origin_id = "s3-frontend"

    # The project gets HTTPS for the first time here, free, on CloudFront's
    # default *.cloudfront.net certificate. The ALB has only ever served
    # plain HTTP.
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id

    # Valid here specifically because Managed-CachingOptimized enables
    # Accept-Encoding normalisation. CloudFront rejects compress = true
    # against a cache policy that does not — which is why the /api/*
    # behaviour below leaves it off.
    compress = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_router[0].arn
    }
  }

  # --- Dynamic: /api/* straight through to the ALB -------------------------
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = "alb-api"

    viewer_protocol_policy = "redirect-to-https"

    # All seven. The default GET/HEAD set would break the entire app: cart
    # uses POST/PUT/DELETE, checkout POSTs, and OPTIONS is the CORS preflight.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # API responses must never be cached. Without this a logged-in user's
    # /api/cart could be served to the next viewer.
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_disabled.id

    # ⚠️ THE MOST LIKELY THING TO BREAK AT RUNTIME IF REMOVED.
    #
    # CloudFront forwards almost NO headers to the origin by default — the
    # cache key defines what gets forwarded, and Managed-CachingDisabled
    # includes none. api.js sets `Authorization: Bearer <token>` on every
    # authenticated call; without this policy that header is stripped at the
    # edge and every authenticated request 401s while looking, from the
    # browser, like a broken login.
    #
    # ...ExceptHostHeader rather than plain AllViewer because forwarding the
    # viewer's Host (the *.cloudfront.net name) to the ALB would override the
    # origin's own Host. The Ingress rule has no `host` field so it matches
    # anything and would survive it, but relying on that is relying on a
    # values.yaml comment staying true.
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    # Off deliberately: see the compress comment above. Managed-CachingDisabled
    # does not enable Accept-Encoding normalisation, and CloudFront rejects the
    # combination. JSON payloads here are small.
    compress = false
  }

  # NO custom_error_response BLOCKS. See aws_cloudfront_function above — they
  # are distribution-wide and would rewrite genuine API 403s and 404s into
  # 200s.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # No domain, no ACM certificate, no cost. Serves on
    # https://<id>.cloudfront.net with a certificate AWS manages.
    cloudfront_default_certificate = true
  }
}

# Lets exactly this distribution read the bucket, and nothing else. The
# AWS:SourceArn condition is what makes it "this distribution" rather than
# "the CloudFront service", which would let anyone else's distribution read
# it if they knew the bucket name.
data "aws_iam_policy_document" "frontend_bucket" {
  count = var.enable_cloudfront ? 1 : 0

  statement {
    sid    = "AllowCloudFrontRead"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend[0].arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  count = var.enable_cloudfront ? 1 : 0

  bucket = aws_s3_bucket.frontend[0].id
  policy = data.aws_iam_policy_document.frontend_bucket[0].json

  # The public access block sets block_public_policy; applying a bucket
  # policy while that is being created is a race S3 resolves by rejecting
  # one of them. Ordering it explicitly avoids an intermittent apply failure.
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# --- CI permissions --------------------------------------------------------
#
# Attached to the EXISTING github-actions-sports-store-frontend-ecr-push role
# from github-oidc.tf — no new role, no new trust policy, no static keys. The
# frontend workflow already assumes this role to push to ECR; the deploy-static
# job added in the same milestone reuses the identical OIDC assume and gets
# these extra permissions with it.
data "aws_iam_policy_document" "frontend_deploy_static" {
  count = var.enable_cloudfront ? 1 : 0

  # ListBucket is on the BUCKET arn, the object actions are on the arn/*.
  # `aws s3 sync` needs the list to work out what has changed; without it the
  # sync fails rather than silently re-uploading everything.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.frontend[0].arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.frontend[0].arn}/*"]
  }

  # Scoped to this one distribution. CreateInvalidation is the only CloudFront
  # action CI needs — it cannot reconfigure or delete the distribution.
  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.main[0].arn]
  }
}

resource "aws_iam_role_policy" "frontend_deploy_static" {
  count = var.enable_cloudfront ? 1 : 0

  name   = "deploy-static"
  role   = aws_iam_role.github_actions_push["sports-store-frontend"].id
  policy = data.aws_iam_policy_document.frontend_deploy_static[0].json
}
