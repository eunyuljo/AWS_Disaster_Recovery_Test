#!/bin/bash
# =============================================================================
# Step 2: Execute DR Drill (non-disruptive test)
# Run AFTER replication reaches CONTINUOUS_REPLICATION state
# =============================================================================
set -euo pipefail

DR_REGION="ap-northeast-1"

echo "=== DR Drill: Initiate Recovery Drill ==="

# Get source server ID
SOURCE_SERVER_ID=$(aws drs describe-source-servers \
  --region "$DR_REGION" \
  --query 'items[0].sourceServerID' \
  --output text)

if [ "$SOURCE_SERVER_ID" = "None" ] || [ -z "$SOURCE_SERVER_ID" ]; then
  echo "ERROR: No source server found. Ensure agent is installed and replicating."
  exit 1
fi

echo "Source Server ID: $SOURCE_SERVER_ID"
echo ""

# Check replication state
REPLICATION_STATE=$(aws drs describe-source-servers \
  --region "$DR_REGION" \
  --query 'items[0].dataReplicationInfo.dataReplicationState' \
  --output text)

echo "Current replication state: $REPLICATION_STATE"

if [ "$REPLICATION_STATE" != "CONTINUOUS_REPLICATION" ]; then
  echo "WARNING: Replication not yet in continuous state. Drill may use stale data."
  read -p "Continue anyway? (y/N): " CONFIRM
  [ "$CONFIRM" != "y" ] && exit 0
fi

echo ""
echo "=== Starting DR Drill (non-disruptive) ==="
JOB_ID=$(aws drs start-recovery \
  --region "$DR_REGION" \
  --is-drill \
  --source-servers "sourceServerID=$SOURCE_SERVER_ID" \
  --query 'job.jobID' \
  --output text)

echo "DR Drill Job ID: $JOB_ID"
echo ""
echo "=== Monitor Drill Progress ==="
echo "  aws drs describe-jobs --region $DR_REGION --filters jobIDs=$JOB_ID"
echo ""
echo "=== After Drill Verification ==="
echo "1. Check the recovery instance in EC2 console (DR region: $DR_REGION)"
echo "2. Verify nginx is running on the recovery instance"
echo "3. Compare content with source server"
echo ""
echo "=== Cleanup Drill Instance ==="
echo "When done testing:"
echo "  aws drs terminate-recovery-instances --region $DR_REGION --recovery-instance-ids <instance-id>"
