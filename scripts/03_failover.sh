#!/bin/bash
# =============================================================================
# Step 3: Execute Actual Failover (production DR scenario)
# Use this when simulating actual disaster recovery
# =============================================================================
set -euo pipefail

DR_REGION="ap-northeast-1"

echo "=== FAILOVER: Start Recovery (Non-Drill) ==="
echo "WARNING: This simulates an actual failover (not a drill)."
read -p "Continue? (y/N): " CONFIRM
[ "$CONFIRM" != "y" ] && exit 0

SOURCE_SERVER_ID=$(aws drs describe-source-servers \
  --region "$DR_REGION" \
  --query 'items[0].sourceServerID' \
  --output text)

echo "Source Server ID: $SOURCE_SERVER_ID"

JOB_ID=$(aws drs start-recovery \
  --region "$DR_REGION" \
  --source-servers "sourceServerID=$SOURCE_SERVER_ID" \
  --query 'job.jobID' \
  --output text)

echo "Failover Job ID: $JOB_ID"
echo ""
echo "=== Monitor ==="
echo "  aws drs describe-jobs --region $DR_REGION --filters jobIDs=$JOB_ID"
echo ""
echo "=== After Successful Failover ==="
echo "1. Update DNS / Route53 to point to recovery instance"
echo "2. Verify application functionality"
echo "3. When ready to failback, run 04_failback.sh"
