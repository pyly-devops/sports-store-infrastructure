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
