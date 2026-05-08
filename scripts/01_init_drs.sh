#!/bin/bash
# =============================================================================
# Step 1: Initialize DRS in DR region and install agent on source server
# Run AFTER terraform apply completes
# =============================================================================
set -euo pipefail

DR_REGION="ap-northeast-1"
SOURCE_INSTANCE_ID=$(terraform output -raw source_server_instance_id)

echo "=== Step 1: Initialize DRS Service ==="
aws drs initialize-service --region "$DR_REGION" 2>/dev/null || echo "DRS already initialized"

echo ""
echo "=== Step 2: Get DRS Agent Credentials ==="
ACCESS_KEY=$(terraform output -raw drs_agent_access_key_id)
SECRET_KEY=$(terraform output -raw drs_agent_secret_access_key)
echo "Access Key: $ACCESS_KEY"
echo "Secret Key: (use 'terraform output -raw drs_agent_secret_access_key' to view)"

echo ""
echo "=== Step 3: Install DRS Agent on Source Server ==="
echo "Connect to source server via SSM and run:"
echo ""
echo "  aws ssm start-session --target $SOURCE_INSTANCE_ID --region ap-northeast-2"
echo ""
echo "Then inside the session:"
echo ""
echo "  sudo su -"
echo "  cd /tmp"
echo "  ./aws-replication-installer-init --region $DR_REGION --no-prompt"
echo ""
echo "When prompted, enter:"
echo "  AWS Access Key ID: $ACCESS_KEY"
echo "  AWS Secret Access Key: <use terraform output>"
echo ""
echo "=== Step 4: Monitor Replication ==="
echo "After agent installation, monitor with:"
echo "  aws drs describe-source-servers --region $DR_REGION"
echo ""
echo "Wait for data_replication_info.dataReplicationState = 'CONTINUOUS_REPLICATION'"
