# Secure File Drop (AWS S3 + EC2 + Presigned URLs)

A minimal, production‑ready pattern for receiving and sharing files on AWS without creating extra IAM users or making a bucket public.

**What you get**
- Private **S3** bucket with **versioning + encryption**
- Lightweight **EC2** “ingress box” with an **instance role** (no static keys)
- Two helper commands to mint short‑lived links:
  - `filedrop-presign-put` → temporary **upload** (PUT) URL
  - `filedrop-presign-get` → temporary **download** (GET) URL

> This README includes **ready‑to‑run examples** wired to the demo bucket: `nuha-secure-file-drop-v1` in **us-east-2**.

---

## 📐 Architecture (at a glance)
```
[External user]
    |  (PUT via presigned URL)
    v
Amazon S3 (private)  <——  EC2 instance (has IAM role)
    ^                        |
    |  (GET via presigned)   | systemd timer syncs /opt/filedrop/uploads -> s3://<bucket>/uploads/
    |                        |
  Your browser/CLI       Helper scripts: filedrop-presign-{get,put}
```

---

## ✅ Prerequisites
- **Bucket:** `nuha-secure-file-drop-v1` (region **us-east-2**), versioning enabled, encryption SSE‑S3
- **EC2 instance** (Amazon Linux) with an attached role that allows **only** this bucket:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::nuha-secure-file-drop-v1" },
      { "Effect": "Allow", "Action": ["s3:PutObject","s3:GetObject"], "Resource": "arn:aws:s3:::nuha-secure-file-drop-v1/*" }
    ]
  }
  ```
- **User‑data** installed (this repo’s script) which drops in:
  - A sync service: mirrors `/opt/filedrop/uploads` → `s3://<bucket>/uploads/`
  - Helpers: `filedrop-presign-get` and `filedrop-presign-put`
  - Config: `/etc/filedrop.conf`

**/etc/filedrop.conf** (key lines)
```bash
BUCKET="nuha-secure-file-drop-v1"
REGION="us-east-2"
PREFIX="uploads"
EXPIRES_DEFAULT=3600
```

---

## 🚀 Quick Start (with the demo bucket)
All commands run **on the EC2 instance**.

### 1) Generate an **upload** link (PUT)
Create a URL that lets someone upload a specific file **without AWS creds**:
```bash
# Allows a collaborator to upload to: s3://nuha-secure-file-drop-v1/uploads/incoming/newfile.bin
filedrop-presign-put incoming/newfile.bin 900   # 15-minute expiry
```
Share the printed URL with your collaborator. They upload from their machine:
```bash
curl -X PUT -T ./newfile.bin "<PASTE_URL_FROM_YOU>"
```

### 2) Verify the object exists
```bash
aws s3 ls s3://nuha-secure-file-drop-v1/uploads/incoming/ --region us-east-2
# or inspect metadata
aws s3api head-object --bucket nuha-secure-file-drop-v1 --key uploads/incoming/newfile.bin --region us-east-2
```

### 3) Generate a **download** link (GET)
```bash
filedrop-presign-get incoming/newfile.bin 600   # 10-minute expiry
# Open the printed URL in a browser to download
```

> 🔑 **Keys & paths**
> - The `PREFIX` is `uploads/` by default. When you presign for `incoming/newfile.bin`, the S3 key becomes `uploads/incoming/newfile.bin`.
> - The uploader’s **local filename** doesn’t affect the S3 key.

---

## 📦 Alternative: Drop files on the instance, let it sync
Instead of sending a PUT URL, you can place files on EC2 and let the timer mirror them to S3.
```bash
echo "hello" > /opt/filedrop/uploads/hello.txt
# Force an immediate sync (timer also runs every 5 min)
sudo systemctl start filedrop-sync.service
```
Then share via a GET link:
```bash
filedrop-presign-get hello.txt 600
```

---

## 🧰 Helper scripts (reference)
These are installed by user‑data; include them here for completeness.

**`filedrop-presign-get` (bash wrapper around `aws s3 presign` for GET)**
```bash
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
```

**`filedrop-presign-put` (Python + boto3, proper PUT presign, region‑aware)**
```python
#!/usr/bin/env python3
import os, sys, boto3
from botocore.config import Config

CONF = "/etc/filedrop.conf"
cfg = {"BUCKET":"", "PREFIX":"", "EXPIRES_DEFAULT":"3600", "REGION":""}

# Load config
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
```

> If you’re not using the provided user‑data, ensure **Python 3 + boto3** are installed on the instance: `sudo yum/dnf install python3 python3-pip && sudo python3 -m pip install --upgrade boto3`.

---

## 🔒 Security Notes
- Bucket stays **private**; **Block Public Access** remains **ON**.
- Use **short expirations** (5–15 minutes) for presigned URLs; share via secure channels.
- IAM role is **least privilege** and scoped to this bucket only.
- Turn on **S3 server‑side encryption** (SSE‑S3 is enabled by default in examples).
- (Optional) Add **lifecycle rules** to clean up non‑current versions.

---

## 💸 Cost Overview
- **S3:** storage + request charges (+ versioning overhead);
- **EC2:** instance hours (use t3.micro/t4g.micro);
- **Data transfer:** egress on downloads via GET links.

---

## 🐞 Troubleshooting
- **`TemporaryRedirect` with an endpoint** → regenerate the URL for the **bucket’s region** (`us-east-2`). Ensure `/etc/filedrop.conf` has `REGION="us-east-2"`.
- **`Unable to locate credentials` on EC2** → no instance role attached or IMDS disabled. Attach the role; retry.
- **`AccessDenied`** → role policy must include `s3:PutObject` / `s3:GetObject` on `nuha-secure-file-drop-v1/*` and `s3:ListBucket` on the bucket.
- **Not seeing files when using the sync path** → start the sync once: `sudo systemctl start filedrop-sync.service`; check `/var/log/filedrop/sync.log`.

---

## 📝 License
MIT (see `LICENSE`).

---

## 🙌 Credits
- Built with core AWS services (S3, EC2, IAM). No frameworks required.


---

## 📁 Repository Structure
```
secure-file-drop/
├─ README.md
├─ LICENSE
├─ .gitignore
├─ user-data/
│  └─ user-data.sh
├─ scripts/
│  ├─ filedrop-presign-get
│  └─ filedrop-presign-put
└─ docs/
   └─ diagram.mmd
```

### .gitignore
```
__pycache__/
*.pyc
.env
.DS_Store
```

### LICENSE (MIT)
```
MIT License

Copyright (c) 2025 Nuha Nishat

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 🧩 Scripts

#### `scripts/filedrop-presign-get`
```bash
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
# default to REGION from config, fallback to us-east-1
aws s3 presign "s3://${BUCKET}/${KEY}" --expires-in "$EXPIRES" --region "${REGION:-us-east-1}"
```

#### `scripts/filedrop-presign-put`
```python
#!/usr/bin/env python3
import os, sys, boto3
from botocore.config import Config

CONF = "/etc/filedrop.conf"
cfg = {"BUCKET":"", "PREFIX":"", "EXPIRES_DEFAULT":"3600", "REGION":""}

# Load config
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
```

> Make both scripts executable when committing them elsewhere: `chmod +x scripts/*`

---

## ☁️ User Data

`user-data/user-data.sh` — Bootstrap the EC2 instance with everything needed (Amazon Linux 2/2023):
```bash
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
```

---

## 🖼️ Diagram (Mermaid)
Save as `docs/diagram.mmd` and embed in README. GitHub renders Mermaid automatically.
```mermaid
graph LR
  A[External User] -- PUT (presigned) --> B[(Amazon S3<br/>Private Bucket)]
  C[EC2 Ingress Instance\n(IAM Role, no keys)] -- Sync /opt/filedrop/uploads --> B
  D[Your Browser/CLI] -- GET (presigned) --> B
  subgraph EC2
    C
  end
  subgraph S3
    B
  end
```

> In README, include: `![Architecture](docs/diagram.mmd)` (GitHub’s Markdown renders Mermaid diagrams inline).
