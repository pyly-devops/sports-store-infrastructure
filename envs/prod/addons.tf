# The 4 core EKS managed add-ons, wired into module.eks's cluster_addons in
# eks.tf. AWS handles each add-on's own DaemonSet/Deployment lifecycle and
# picks a version compatible with the cluster's Kubernetes version.
locals {
  cluster_addons = {
    # before_compute = true makes the module create this before the node
    # group, not after (its default). Nodes coming up before vpc-cni exists
    # would join with no pod networking at all.
    vpc-cni = {
      before_compute = true

      configuration_values = jsonencode({
        env = {
          # Default VPC CNI IP allocation caps a t3.small at 11 pods; two
          # nodes give 22 slots, and system DaemonSets (aws-node, kube-proxy,
          # coredns, ebs-csi-node) eat roughly half before a single app pod
          # schedules. Prefix delegation assigns /28 prefixes instead of
          # secondary IPs, raising the cap to ~110 pods/node. Free, and the
          # difference between the cluster working and pods stuck Pending
          # with "failed to assign an IP address".
          ENABLE_PREFIX_DELEGATION = "true"
        }
      })
    }

    kube-proxy = {}

    # No before_compute: installed after the node group by the module's
    # default ordering. With zero nodes it would just sit Degraded waiting
    # for somewhere to schedule.
    coredns = {}

    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }
}
