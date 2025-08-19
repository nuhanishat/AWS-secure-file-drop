#!/bin/bash -xe

# Package manager and basics
if command -v dnf >/dev/null 2>&1; then PM=dnf; else PM=yum; fi
$PM -y update
$PM -y install awscli jq python3 python3-pip
python3 -m pip install --upgrade boto3 botocore

# Directories and config
install -d -m 0755 /opt/filedrop/uploads /opt/filedrop/incoming /var/log/filedrop
cat >/etc/filedrop.conf <<'EOF'
BUCKET="nuha-secure-file-drop-v1"
REGION="us-east-2"
PREFIX="uploads"
EXPIRES_DEFAULT=3600
EOF

# Sync script
cat >/usr/local/bin/filedrop-sync <<'EOF'
#!/bin/bash
set -euo pipefail
source /etc/filedrop.conf
LOG=/var/log/filedrop/sync.log
UPDIR=/opt/filedrop/uploads

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "$(date -Is) no-credentials: instance role not available; skipping sync" >> "$LOG"
  exit 0
fi

DEST="s3://${BUCKET}"
if [[ -n "${PREFIX:-}" ]]; then DEST="${DEST%/}/${PREFIX}"; fi

mkdir -p "$UPDIR"
echo "$(date -Is) syncing $UPDIR -> $DEST" >> "$LOG"
aws s3 sync "$UPDIR" "$DEST" --delete --region "${REGION:-us-east-1}" >> "$LOG" 2>&1 || {
  echo "$(date -Is) sync failed" >> "$LOG"
  exit 1
}
echo "$(date -Is) sync complete" >> "$LOG"
EOF
chmod +x /usr/local/bin/filedrop-sync

# GET presigner
cat >/usr/local/bin/filedrop-presign-get <<'EOF'
#!/bin/bash
set -euo pipefail
source /etc/filedrop.conf
REL="${1:-}"
if [[ -z "$REL" ]]; then
  echo "Usage: filedrop-presign-get <relative-path-under-PREFIX> [expires-seconds]" >&2
  exit 1
fi
EXPIRES="${2:-$EXPIRES_DEFAULT}"
KEY="${PREFIX:+$PREFIX/}$REL"
aws s3 presign "s3://${BUCKET}/${KEY}" --expires-in "$EXPIRES" --region "${REGION:-us-east-1}"
EOF
chmod +x /usr/local/bin/filedrop-presign-get

# PUT presigner (Python)
cat >/usr/local/bin/filedrop-presign-put <<'PY'
#!/usr/bin/env python3
import os, sys, boto3
from botocore.config import Config

CONF = "/etc/filedrop.conf"
cfg = {"BUCKET":"", "PREFIX":"", "EXPIRES_DEFAULT":"3600", "REGION":""}

if os.path.exists(CONF):
    for line in open(CONF):
        line=line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        k,v = line.split('=',1)
        cfg[k.strip()] = v.strip().strip('"')

if len(sys.argv) < 2:
    print("Usage: filedrop-presign-put <relative-path-under-PREFIX> [expires-seconds]", file=sys.stderr)
    sys.exit(1)

rel = sys.argv[1]
expires = int(sys.argv[2]) if len(sys.argv) > 2 else int(cfg.get("EXPIRES_DEFAULT","3600"))

bucket = cfg.get("BUCKET","" ).strip()
prefix = cfg.get("PREFIX","" ).strip()
region = cfg.get("REGION","" ).strip()
if not bucket:
    print("Error: BUCKET is not set in /etc/filedrop.conf", file=sys.stderr); sys.exit(2)
if not region:
    print("Error: REGION is not set in /etc/filedrop.conf (e.g., us-east-2)", file=sys.stderr); sys.exit(3)

key = f"{prefix}/{rel}" if prefix else rel
endpoint = f"https://s3.{region}.amazonaws.com"
s3 = boto3.client("s3", region_name=region,
                  endpoint_url=endpoint,
                  config=Config(signature_version="s3v4", s3={"addressing_style":"virtual"}))

url = s3.generate_presigned_url(
    ClientMethod="put_object",
    Params={"Bucket": bucket, "Key": key},
    ExpiresIn=expires,
    HttpMethod="PUT"
)
print(url)
PY
chmod +x /usr/local/bin/filedrop-presign-put

# systemd service + timer
cat >/etc/systemd/system/filedrop-sync.service <<'EOF'
[Unit]
Description=Sync /opt/filedrop/uploads to S3
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/filedrop.conf
ExecStart=/usr/local/bin/filedrop-sync
Nice=10
EOF

cat >/etc/systemd/system/filedrop-sync.timer <<'EOF'
[Unit]
Description=Run filedrop sync every 5 minutes

[Timer]
OnBootSec=30sec
OnUnitActiveSec=5min
AccuracySec=30sec
Unit=filedrop-sync.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now filedrop-sync.timer

# convenience
chown -R ec2-user:ec2-user /opt/filedrop

# MOTD
cat >/etc/motd <<'EOF'
Secure File Drop ready.

Upload files to:  /opt/filedrop/uploads
They will sync to: s3://nuha-secure-file-drop-v1/uploads (every ~5 min)

Presign helpers:
  filedrop-presign-get <relative-path> [ttl]
  filedrop-presign-put <relative-path> [ttl]
Example:
  echo "hello" > /opt/filedrop/uploads/test.txt
  filedrop-presign-get test.txt 3600
EOF
