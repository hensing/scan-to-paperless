# 📠 Scan to Paperless Bridge

[![Docker Build & Publish](https://github.com/hensing/scan-to-paperless/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/hensing/scan-to-paperless/actions/workflows/docker-publish.yml)
![Platform](https://img.shields.io/badge/platform-linux%2Famd64%20%7C%20linux%2Farm64-blue)
![License](https://img.shields.io/badge/license-MIT-green)

**Author:** Dr. Henning Dickten ([@hensing](https://github.com/hensing))

A lightweight, secure, and Dockerized bridge designed for **Raspberry Pi** and generic Linux servers. It provides a Samba (SMB) share for hardware document scanners.

Once a scan is saved to the share, this container detects the completed file, uploads it directly to **Paperless-ngx** via API, and optionally archives or cleans up the local file.

Supports both **single-user** (simple env var config) and **multi-user** mode (one share and API key per person).

---

### 🔄 How it works

**Single-user mode**

```mermaid
graph LR
    A[🖨️ Hardware Scanner] -- SMB Port 445 --> B(📂 /data/inbox)
    B --> C[🐳 Container Watcher]
    C -- API Token --> D[📄 Paperless-NGX]
    C -- Move/Delete --> E(📦 /data/archive)
```

**Multi-user mode**

```mermaid
graph TD
    SCAN[🖨️ Hardware Scanner]

    subgraph alice [Alice]
        direction TB
        AI(📂 alice_scans)
        AW[🐳 Watcher]
        AA(📦 archive)
        AI --> AW --> AA
    end

    subgraph bob [Bob]
        direction TB
        BI(📂 bob_docs)
        BW[🐳 Watcher]
        BA(📦 archive)
        BI --> BW --> BA
    end

    PL[📄 Paperless-NGX]

    SCAN -- SMB: alice_scans --> AI
    SCAN -- SMB: bob_docs --> BI
    AW -- Alice's API Key --> PL
    BW -- Bob's API Key --> PL
```

## ✨ Features

- **🚀 Multi-Arch Support:** Optimized for `linux/amd64` and `linux/arm64` (Raspberry Pi).
- **👥 Multi-User Support:** Each user gets their own Samba share, SMB credentials, and Paperless-NGX API key.
- **🔒 Rootless by Design:** Never runs as root, not even briefly at startup — fixed UID/GID 65532:65532 (the "distroless nonroot" convention, deliberately *not* 1000, to avoid colliding with a real host login user) baked into the image. Port 445 is remapped from an unprivileged internal port via Docker's own port publishing, so the container needs zero Linux capabilities.
- **📂 Samba Integration:** Built-in SMB server compliant with modern scanners.
- **⚡ Smart Detection:** Uses `inotify` to detect `close_write` events (prevents processing incomplete files).
- **🏷️ Auto-Tagging:** Automatically apply tags to uploaded documents — configurable per user in multi-user mode.
- **🧹 Auto-Cleanup:** Options to archive or delete files after successful upload.
- **🛡️ SSL Support:** Full support for HTTPS and self-signed certificates.

## 🔗 Recommended Workflow

This tool works best as part of a modern document management ecosystem. We highly recommend checking out:

* **[Paperless-ngx Documentation](https://docs.paperless-ngx.com/)**: The official documentation for the backend system.
* **[Paperless-GPT](https://github.com/icereed/paperless-gpt)**: An amazing tool to add AI-powered analysis, tagging, and renaming to your documents after they have been uploaded.

## 🚀 Quick Start

### Single-User Mode

#### 1. Configuration

Create your `.env` file based on the example:

```bash
cp .env.example .env
```

**Minimal `.env` example:**

```dotenv
PAPERLESS_URL=https://paperless.local:8000
PAPERLESS_API_KEY=your-super-secret-token
SMB_USER=scanner
SMB_PASSWORD=scan123
```

> ⚠️ **`scan123` is just an example value, not a real default you should keep.** Change `SMB_PASSWORD` to a strong, unique password before starting the container — this share is reachable by anything on your network. The container will log a loud warning at startup for as long as the password is left at `scan123`.

#### 1b. Host Permissions

This container **always** runs as a fixed UID/GID (`65532:65532` by default) and never as root — not even transiently at startup. Before the first start, make sure `./data` and `./config` are owned by (or writable by) UID/GID `65532` on the host:

```bash
mkdir -p data config
chown -R 65532:65532 data config
```

The container can no longer fix bind-mount ownership for you (that would require a root step, which has been deliberately removed).

**Why 65532 and not 1000?** Docker doesn't remap container UIDs into a separate namespace by default — "UID 1000 in the container" is literally the same UID as a host account, and on single-user Debian/Raspberry Pi OS installs, UID 1000 is almost always the operator's own (often sudo-capable) login. Since this container runs a network-facing SMB service, a container escape running as that UID would inherit the operator's file access and could potentially piggyback on a still-valid `sudo` credential cache. `65532` is the widely-used "distroless nonroot" convention — deliberately outside both the Linux system-service range (0–999) and the human-user range (1000+), so it won't collide with a real login account. If you'd rather match your own host user than run the one-time `chown` (accepting the collision consideration above), rebuild with `--build-arg APP_UID=<uid> --build-arg APP_GID=<gid>` and update `user:` in your compose file to match.

#### 2. Docker Compose

Create a `docker-compose.yml` (or use the one provided):

```yaml
services:
  scan-to-paperless:
    image: ghcr.io/hensing/scan-to-paperless:latest
    container_name: scan-to-paperless
    restart: unless-stopped
    user: "65532:65532"
    security_opt:
      - "no-new-privileges:true"
    cap_drop:
      - "ALL"
    ports:
      - "445:8445"
    env_file:
      - .env
    volumes:
      - ./data:/data
      - ./config:/config:ro
```

Start the container:

```bash
docker compose up -d
```

#### 3. Scanner Setup

Configure your physical scanner (Brother, Canon, HP, etc.) with these settings:

* **Protocol:** SMB / CIFS
* **Server:** IP of your Docker host
* **Port:** 445
* **Share Name:** `scanner` (default)
* **Username:** `scanner` (default)
* **Password:** `scan123` (default — ⚠️ example only, change it in `.env` before going live)

---

### 👥 Multi-User Mode

Multi-user mode activates automatically when `./config/users.conf` exists. Each user gets an isolated Samba share and uploads to Paperless with their own API key.

#### 1. Create the user config

```bash
mkdir -p config
cp config/users.conf.example config/users.conf
```

Edit `config/users.conf` — one user per line, colon-separated:

```
# smb_user:smb_password:smb_share:paperless_api_key:paperless_tags(optional)
alice:secretpassword1:alice_scans:paperless-api-token-alice:scanned,alice
bob:secretpassword2:bob_docs:paperless-api-token-bob:scanned,bob
```

#### 2. Set global settings in `.env`

Only `PAPERLESS_URL` and optional processing settings are needed. The `SMB_*` and `PAPERLESS_API_KEY` variables are ignored in multi-user mode.

```dotenv
PAPERLESS_URL=https://paperless.local:8000
```

Make sure you've also completed the [Host Permissions](#1b-host-permissions) step (`chown -R 65532:65532 data config`) — it applies to multi-user mode too.

The image ships with a fixed pool of 32 internal Samba accounts (see `config/users.conf.example`); rebuild with `--build-arg SMB_POOL_SIZE=<N>` if you need more than 32 concurrent users.

#### 3. Start the container

```bash
docker compose up -d
```

Each user's files land in `/data/<smb_user>/inbox` and are archived to `/data/<smb_user>/archive`.

> **Upgrading from single-user:** No changes required. Single-user mode is auto-detected when `users.conf` is absent.

---

## ⚙️ Configuration Reference

### Global Settings (`.env`)

| Variable | Description | Default | Required |
| :--- | :--- | :--- | :---: |
| `PAPERLESS_URL` | Full URL to Paperless-NGX (e.g., `http://192.168.1.5:8000`) | - | ✅ |
| `PAPERLESS_VERIFY_SSL` | Verify SSL certificates (`false` for self-signed) | `true` | ❌ |
| `WHITELIST` | Allowed file extensions | `pdf,jpg,png,bmp` | ❌ |
| `ARCHIVE` | `true` = Move to archive folder, `false` = Delete after upload | `true` | ❌ |
| `UPLOAD_TIMEOUT` | Max time (seconds) for API upload | `30` | ❌ |
| `SCAN_SETTLE_TIME` | Seconds to wait after detection before upload | `5` | ❌ |

> There is no `PUID`/`PGID` setting — the container always runs as fixed UID/GID `65532:65532`. See [Host Permissions](#1b-host-permissions).

### Single-User Settings (`.env`)

Ignored when `config/users.conf` is present.

| Variable | Description | Default |
| :--- | :--- | :--- |
| `PAPERLESS_API_KEY` | API Token from Paperless Settings → API Tokens | - |
| `PAPERLESS_TAGS` | Comma-separated tags to apply | `""` |
| `SMB_USER` | Username for the scanner to login | `scanner` |
| `SMB_PASSWORD` | Password for the scanner | `scan123` |
| `SMB_SHARE` | Name of the SMB share | `scanner` |

### Multi-User Settings (`config/users.conf`)

| Field | Description | Required |
| :--- | :--- | :---: |
| `smb_user` | Linux/SMB username — unique, no spaces | ✅ |
| `smb_password` | Password for the SMB share | ✅ |
| `smb_share` | Share name visible to the scanner | ✅ |
| `paperless_api_key` | API Token from Paperless Settings → API Tokens | ✅ |
| `paperless_tags` | Comma-separated tags (optional, can be empty) | ❌ |

`smb_user` and `smb_share` must match `^[A-Za-z][A-Za-z0-9_-]*$`; a fixed pool of 32 internal Samba accounts is available by default (`SMB_POOL_SIZE` build arg) — entries beyond that are skipped with a warning until the image is rebuilt with a larger pool.

> **Note on Permissions:** This container never runs as root, not even transiently at startup. It runs as a fixed UID/GID (`65532:65532` by default, overridable at build time via `--build-arg APP_UID`/`APP_GID`) baked into the image at build time — there is no runtime PUID/PGID remapping. Because of this, you are responsible for ensuring `./data` and `./config` are owned by (or writable by) that UID/GID *before* starting the container — the container itself can no longer fix bind-mount ownership, since doing so would require a root step that has been deliberately removed. See [Host Permissions](#1b-host-permissions).

### ⬆️ Migrating from a previous version

This version removes the container's root startup phase entirely. If you're upgrading from an older version:

1. **`PUID`/`PGID` are gone.** Remove them from your `.env`. The container now always runs as UID/GID `65532:65532`.
2. **Rebuild the image** (`docker compose build` / re-pull), not just restart — the new image ships a fixed pool of Samba accounts and a non-root `USER` directive.
3. **`chown -R 65532:65532 ./data ./config` on the host once**, before starting — the container no longer fixes bind-mount ownership for you.
4. Scanner-facing behavior is unchanged (still port `445`, same `users.conf` format); no scanner reconfiguration is needed.
5. Multi-user setups are capped at 32 concurrent users by default; rebuild with `--build-arg SMB_POOL_SIZE=<N>` if you need more.

---

## 📂 Directory Structure

**Single-user mode**

```text
/data
├── inbox/      <-- Scanner saves files here (monitored)
└── archive/    <-- Processed files are moved here (if ARCHIVE=true)
```

**Multi-user mode**

```text
/data
├── alice/
│   ├── inbox/    <-- alice's Samba share (monitored)
│   └── archive/  <-- alice's processed files
└── bob/
    ├── inbox/    <-- bob's Samba share (monitored)
    └── archive/  <-- bob's processed files
```

## 🛠️ Troubleshooting

**🛑 "Upload failed" in logs**
* Check if `PAPERLESS_URL` is reachable from inside the container.
* Verify the API key (`PAPERLESS_API_KEY` or the key in `users.conf`).
* If using a self-signed cert, try setting `PAPERLESS_VERIFY_SSL=false`.
* Increase `SCAN_SETTLE_TIME`. Some network scanners report "finished" before the file is fully flushed to disk.

**🚫 Scanner cannot connect (Network Error)**
* Ensure port **445** is not blocked by a firewall on the host.
* Windows/Mac hosts might use port 445 for their own sharing service. Ensure port 445 is free or use a different external port (note: many scanners hardcode 445).

**📄 File is ignored**
* Check the `WHITELIST` in `.env`.
* The container waits for the `close_write` event. Ensure the scanner finishes writing the file completely.

**👥 Multi-user: user cannot connect**
* Verify the share name in `users.conf` matches what the scanner is configured with.
* Check the container logs for `[INIT] Configured N user(s).` — if N is 0, the config file has a parsing issue.
* Ensure all four required fields (`smb_user:smb_password:smb_share:paperless_api_key`) are present.

---

## 🤝 How to Contribute

Contributions, improvements, and bug fixes are welcome!

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a Pull Request.

**Note to Forks:** Please ensure that the original author credit remains intact in the license and documentation when forking or redistributing this project.

## 👨‍💻 Development

Build the image locally:

```bash
docker build -t scan-to-paperless .
```

## 📜 License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.
