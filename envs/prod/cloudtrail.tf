# ---------------------------------------------------------------------------
# CloudTrail — API-call auditing (Milestone 9).
#
# Standalone by design: nothing here references the cluster, the VPC or the
# ALB, so it applies from zero and destroys cleanly on its own. That is the
# opposite of cloudfront.tf, which cannot exist until the Load Balancer
# Controller has produced an ALB and is therefore behind a feature flag.
#
# WHY THIS IS FREE, AND THE ONE WAY IT STOPS BEING FREE:
#
# CloudTrail bills in three ways. The FIRST copy of MANAGEMENT events per
# region is free with no volume cap — that is what this trail is. The other
# two are opt-in and are where every "my CloudTrail bill exploded" story
# comes from:
#
#   Data events   — S3 object-level GET/PUT, Lambda invokes. $0.10 per
#                   100,000. A single busy bucket produces millions. In
#                   Terraform these are `data_resource` blocks inside
#                   `event_selector`; there are DELIBERATELY NONE below, and
#                   their absence is the entire reason this costs nothing.
#                   This matters more now than it would have last month:
#                   cloudfront.tf adds a bucket that CloudFront reads on
#                   every cache miss, and S3 data events would bill for each
#                   one. Worse, if the trail's OWN bucket were ever included,
#                   writing a log would generate an event that writes a log.
#   Insights      — $0.35 per 100,000 analysed. No `insight_selector` below.
#
# Management events are control-plane calls: AssumeRole, RunInstances,
# CreateBucket. For this project that is a few thousand a day at ~1-2 KB
# each, so the S3 storage behind it is pennies even before the 30-day
# lifecycle rule below.
#
# ⚠️ PRE-FLIGHT CHECK, because `terraform plan` cannot catch this:
#     aws cloudtrail describe-trails --query 'trailList[].Name'
# Only the FIRST trail in the account gets the free management-event copy. If
# the account already has one, this becomes a second copy at $2 per 100,000
# events. Terraform has no way to see a trail it does not manage — exactly
# how Milestone 4 discovered the pre-existing GitHub OIDC provider that
# github-oidc.tf now has to `data` rather than `resource`.
# ---------------------------------------------------------------------------

locals {
  cloudtrail_bucket_name = "sports-store-cloudtrail-${data.aws_caller_identity.current.account_id}"

  # Built by hand rather than read from aws_cloudtrail.main.arn. The bucket
  # policy has to exist BEFORE the trail can be created (CloudTrail validates
  # it can write during creation), and the trail needs the bucket — so a real
  # reference in either direction is a dependency cycle. The ARN shape is
  # documented and stable, so composing it breaks the cycle without weakening
  # the SourceArn condition.
  cloudtrail_arn = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/sports-store"
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket = local.cloudtrail_bucket_name

  # NOT OPTIONAL. `terraform destroy` has been proven working since Milestone
  # 4 and the project's ephemeral-infra rule depends on it staying that way.
  # S3 refuses to delete a bucket containing objects, and this bucket starts
  # collecting them within 15 minutes of the trail going live — so without
  # this, the first destroy after the first apply fails and someone has to
  # empty the bucket by hand.
  force_destroy = true
}

# SSE-S3 rather than SSE-KMS. KMS would add a customer-managed key at
# $1/month plus per-request charges, to protect log data that is already
# private to the account. SSE-S3 is free and encrypts at rest just the same.
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Keeps storage bounded without anyone having to remember. 30 days is well
# past useful for a demo account, and the bucket never grows past a few MB.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    # An empty filter means "every object". Required explicitly by AWS
    # provider 5.x — a rule with neither filter nor prefix is rejected at
    # plan time rather than silently applying to nothing.
    filter {}

    expiration {
      days = 30
    }
  }
}

# The bucket policy CloudTrail itself needs. Two statements, both scoped to
# this one trail via AWS:SourceArn — without that condition any trail in any
# account that knew the bucket name could write to it (the confused-deputy
# problem AWS added SourceArn to close).
#
# NO s3:x-amz-acl CONDITION, deliberately. Every older tutorial includes one
# requiring bucket-owner-full-control. Buckets created today default to
# Object Ownership = BucketOwnerEnforced, which DISABLES ACLs outright, and
# CloudTrail correspondingly stops sending the header. Requiring a condition
# key that is never present would deny every write.
data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [local.cloudtrail_arn]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    # Scoped to this account's log prefix, not the whole bucket.
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [local.cloudtrail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

resource "aws_cloudtrail" "main" {
  name           = "sports-store"
  s3_bucket_name = aws_s3_bucket.cloudtrail.id

  # Single-region. A multi-region trail creates a copy per region and only
  # one copy is free; everything this project owns lives in us-east-1 anyway.
  is_multi_region_trail = false

  # Global services (IAM, STS) only ever report into us-east-1, which is
  # var.aws_region here. This is the interesting half of the audit trail —
  # every GitHub Actions OIDC AssumeRoleWithWebIdentity and every IRSA
  # AssumeRole shows up because of this line. Milestone 7 debugged the
  # broken OIDC `sub` condition by reading exactly these events.
  include_global_service_events = true

  # Free, and the whole point of calling something an audit trail: CloudTrail
  # writes a signed digest so tampering with a delivered log file is
  # detectable rather than merely unlikely.
  enable_log_file_validation = true

  event_selector {
    # Both directions. Read-only calls (Describe*, List*) are where
    # reconnaissance shows up, so dropping them would lose the more
    # interesting half.
    read_write_type = "All"

    include_management_events = true

    # NO data_resource BLOCK HERE. See the header — this is the line item
    # that would turn a $0 trail into a metered one. Adding S3 data events
    # for the CloudFront bucket is the specific mistake to avoid.
  }

  # The policy must be in place before CloudTrail will accept the bucket; it
  # test-writes during creation. Terraform cannot infer this from the
  # attribute references alone because the trail refers to the bucket, not to
  # the policy.
  depends_on = [aws_s3_bucket_policy.cloudtrail]
}
