# =============================================================================
# IAM - DRS Agent and Source Server Roles
# =============================================================================

# IAM Role for Source Server (to install and run DRS agent)
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "source_server" {
  name               = "drs-source-server-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = local.common_tags
}

# DRS Agent requires these permissions to communicate with DRS service
data "aws_iam_policy_document" "drs_agent" {
  statement {
    sid = "DRSAgentPermissions"
    actions = [
      "drs:SendAgentMetricsForDrs",
      "drs:SendAgentLogsForDrs",
      "drs:GetAgentInstallationAssetsForDrs",
      "drs:GetAgentCommandForDrs",
      "drs:SendClientLogsForDrs",
      "drs:GetAgentConfirmedResumeInfoForDrs",
      "drs:GetAgentRuntimeConfigurationForDrs",
      "drs:UpdateAgentSourcePropertiesForDrs",
      "drs:UpdateAgentReplicationInfoForDrs",
      "drs:UpdateAgentConversionInfoForDrs",
      "drs:GetAgentReplicationInfoForDrs",
      "drs:DescribeReplicationConfigurationTemplates",
      "drs:DescribeSourceServers",
      "drs:SendClientMetricsForDrs",
      "drs:CreateSourceServerForDrs",
      "drs:TagResource"
    ]
    resources = ["*"]
  }

  statement {
    sid = "S3ReplicationAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::aws-elastic-disaster-recovery-*",
      "arn:aws:s3:::aws-elastic-disaster-recovery-*/*"
    ]
  }

  statement {
    sid = "EC2DescribeAccess"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "drs_agent" {
  name   = "drs-agent-policy"
  policy = data.aws_iam_policy_document.drs_agent.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "drs_agent" {
  role       = aws_iam_role.source_server.name
  policy_arn = aws_iam_policy.drs_agent.arn
}

# SSM for remote management of source server
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.source_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "source_server" {
  name = "drs-source-server-profile"
  role = aws_iam_role.source_server.name

  tags = local.common_tags
}

# IAM credentials for DRS agent installation (access key)
resource "aws_iam_user" "drs_agent" {
  name = "drs-agent-user"
  tags = local.common_tags
}

resource "aws_iam_user_policy_attachment" "drs_agent" {
  user       = aws_iam_user.drs_agent.name
  policy_arn = aws_iam_policy.drs_agent.arn
}

resource "aws_iam_access_key" "drs_agent" {
  user = aws_iam_user.drs_agent.name
}
