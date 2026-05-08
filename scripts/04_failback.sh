#!/bin/bash
# =============================================================================
# Step 4: Failback - Return to source after DR event
# Run AFTER failover is complete and source environment is restored
# =============================================================================
set -euo pipefail

DR_REGION="ap-northeast-1"

echo "=== FAILBACK: Reverse Replication ==="
echo ""
echo "Failback process overview:"
echo "1. Ensure source environment is healthy and accessible"
echo "2. Start failback replication (DR → Source)"
echo "3. Wait for continuous replication"
echo "4. Cutover back to source"
echo ""

# List recovery instances
echo "=== Current Recovery Instances ==="
aws drs describe-recovery-instances \
  --region "$DR_REGION" \
  --query 'items[].{ID:ec2InstanceID,State:ec2InstanceState.name,SourceServer:sourceServerID}' \
  --output table

RECOVERY_INSTANCE_ID=$(aws drs describe-recovery-instances \
  --region "$DR_REGION" \
  --query 'items[0].recoveryInstanceID' \
  --output text)

if [ "$RECOVERY_INSTANCE_ID" = "None" ] || [ -z "$RECOVERY_INSTANCE_ID" ]; then
  echo "ERROR: No recovery instance found."
  exit 1
fi

echo ""
echo "Recovery Instance ID: $RECOVERY_INSTANCE_ID"
echo ""
echo "=== To start failback: ==="
echo "  aws drs start-failback-launch --region $DR_REGION --recovery-instance-ids $RECOVERY_INSTANCE_ID"
echo ""
echo "=== After failback completes: ==="
echo "  aws drs disconnect-source-server --region $DR_REGION --source-server-id <source-server-id>"
echo ""
echo "=== Cleanup (remove all DRS resources): ==="
echo "  terraform destroy"
