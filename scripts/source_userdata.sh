#!/bin/bash
set -euxo pipefail

# Install nginx as workload
amazon-linux-extras install -y nginx1
systemctl enable nginx
systemctl start nginx

# Create a custom page to verify DR recovery
cat > /usr/share/nginx/html/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>DRS Source Server</title></head>
<body>
<h1>AWS DRS Test - Source Server</h1>
<p>Region: ap-northeast-2 (Seoul)</p>
<p>Role: On-premises simulation</p>
<p>Hostname: HOSTNAME_PLACEHOLDER</p>
<p>Timestamp: TIMESTAMP_PLACEHOLDER</p>
</body>
</html>
HTML

# Replace placeholders with actual values
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/" /usr/share/nginx/html/index.html
sed -i "s/TIMESTAMP_PLACEHOLDER/$TIMESTAMP/" /usr/share/nginx/html/index.html

# Install DRS agent prerequisites
yum install -y python3 wget

# Download DRS agent installer (will be run manually after terraform apply)
wget -O /tmp/aws-replication-installer-init \
  "https://aws-elastic-disaster-recovery-${dr_region}.s3.${dr_region}.amazonaws.com/latest/linux/aws-replication-installer-init"
chmod +x /tmp/aws-replication-installer-init

echo "=== Source server setup complete. DRS agent installer downloaded to /tmp/ ==="
