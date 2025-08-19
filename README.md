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
filedrop-presign-put incoming/<FILE_NAME.TYPE> 900   # 15-minute expiry
```
Share the printed URL with your collaborator. They upload from their machine:
```bash
curl -X PUT -T ./<FILE_NAME.TYPE> "<PASTE_URL_FROM_YOU>"
```

### 2) Verify the object exists
```bash
aws s3 ls s3://nuha-secure-file-drop-v1/uploads/incoming/ --region us-east-2
# or inspect metadata
aws s3api head-object --bucket nuha-secure-file-drop-v1 --key uploads/incoming/<FILE_NAME.TYPE> --region us-east-2
```

### 3) Generate a **download** link (GET)
```bash
filedrop-presign-get incoming/<FILE_NAME.TYPE> 600   # 10-minute expiry
# Open the printed URL in a browser to download
```

> 🔑 **Keys & paths**
> - The `PREFIX` is `uploads/` by default. When you presign for `incoming/<FILE_NAME.TYPE>`, the S3 key becomes `uploads/incoming/<FILE_NAME.TYPE>`.
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

## ☁️ User Data

`user-data/user-data.sh` — Bootstrap the EC2 instance with everything needed (Amazon Linux 2/2023)

---

## 🧰 Helper scripts (reference)
These are installed by user‑data:

**`filedrop-presign-get` (bash wrapper around `aws s3 presign` for GET)**

**`filedrop-presign-put` (Python + boto3, proper PUT presign, region‑aware)**

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

