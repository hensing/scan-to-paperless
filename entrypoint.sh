#!/bin/bash
# scan-to-paperless entrypoint
# Author: Dr. Henning Dickten (@hensing)

set -e

# This container is rootless by design and must never run as root. The
# image's own USER directive already enforces this; this is a self-check in
# case of a misconfigured `docker run --user root` (or similar) override.
if [ "$(id -u)" = "0" ]; then
    echo "[ERROR] This container must never run as root. Refusing to start." >&2
    exit 1
fi

USERS_CONFIG=${USERS_CONFIG:-"/config/users.conf"}
SMB_CONF="/tmp/smb.conf"
SMB_USERMAP="/tmp/usermap"
SMB_POOL_SIZE=${SMB_POOL_SIZE:-32}

# --- Global Settings ---
PAPERLESS_URL=${PAPERLESS_URL:-""}
PAPERLESS_VERIFY_SSL=${PAPERLESS_VERIFY_SSL:-true}
WHITELIST=${WHITELIST:-"pdf,jpg,png,bmp"}
ARCHIVE=${ARCHIVE:-true}
UPLOAD_TIMEOUT=${UPLOAD_TIMEOUT:-30}
SCAN_SETTLE_TIME=${SCAN_SETTLE_TIME:-5}

if [ -z "$PAPERLESS_URL" ]; then
    echo "[ERROR] PAPERLESS_URL must be set."
    exit 1
fi

echo "╔══════════════════════════════╗"
echo "║      SCAN TO PAPERLESS       ║"
echo "║     Dr. Henning Dickten      ║"
echo "║            2025              ║"
echo "╚══════════════════════════════╝"
echo "[CONFIG] Paperless URL: $PAPERLESS_URL"
echo "[CONFIG] Archive: $ARCHIVE | Whitelist: $WHITELIST | Settle: ${SCAN_SETTLE_TIME}s"
echo "[CONFIG] User UID: $(id -u), GID: $(id -g)"

# --- Helper Functions ---

check_whitelist() {
    local filename="$1"
    local ext="${filename##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    IFS=',' read -ra EXT_ARRAY <<< "$WHITELIST"
    for allowed_ext in "${EXT_ARRAY[@]}"; do
        allowed_ext=$(echo "$allowed_ext" | tr '[:upper:]' '[:lower:]' | xargs)
        [ "$ext" = "$allowed_ext" ] && return 0
    done
    return 1
}

# Uploads via a curl config file (-K) rather than -H on the command line, so
# the Paperless API token never appears in this process's argv (and is thus
# not visible via `ps`/`/proc/<pid>/cmdline` to anything else sharing the
# container's PID namespace).
upload_to_paperless() {
    local filepath="$1"
    local api_key="$2"
    local tags="$3"
    local filename
    filename=$(basename "$filepath")

    echo "[UPLOAD] Uploading $filename..."

    local curl_opts=()
    [ "$PAPERLESS_VERIFY_SSL" = "false" ] && curl_opts+=("--insecure")

    local curl_form=("-F" "document=@$filepath")
    [ -n "$tags" ] && curl_form+=("-F" "tags=$tags")

    local hdr_file
    hdr_file=$(mktemp)
    chmod 600 "$hdr_file"
    printf 'header = "Authorization: Token %s"\n' "$api_key" > "$hdr_file"

    local rc=0
    if curl "${curl_opts[@]}" \
          --max-time "$UPLOAD_TIMEOUT" \
          -X POST \
          -K "$hdr_file" \
          "${curl_form[@]}" \
          "$PAPERLESS_URL/api/documents/post_document/"; then
        echo "[SUCCESS] Upload complete: $filename"
    else
        rc=1
        echo "[ERROR] Upload failed: $filename"
    fi

    rm -f "$hdr_file"
    return $rc
}

# Warns (does not fail) if a mounted credential file is group/world
# readable. The container cannot chmod host-owned bind mounts itself once it
# never runs as root, so this is a best-effort, read-only nudge.
check_conf_perms() {
    local f="$1" mode mode3 group_digit other_digit
    [ -e "$f" ] || return 0
    mode=$(stat -c '%a' "$f" 2>/dev/null) || return 0
    mode3="${mode: -3}"
    group_digit="${mode3:1:1}"
    other_digit="${mode3:2:1}"
    if (( (group_digit & 4) || (other_digit & 4) )); then
        echo "[WARN] $f is group/world readable (mode $mode). It contains plaintext credentials -- recommend: chmod 600 $f on the host." >&2
    fi
}

# Watcher for a single user's inbox directory.
# All config is passed as arguments to avoid issues with subshell variable scoping.
watch_inbox() {
    local label="$1"
    local inbox_dir="$2"
    local archive_dir="$3"
    local api_key="$4"
    local tags="$5"

    echo "[INFO] [$label] Watching $inbox_dir..."

    inotifywait -m "$inbox_dir" -e close_write -e moved_to --format '%f' | while read -r FILENAME; do
        echo "[$label] Detected: $FILENAME"
        local FILEPATH="$inbox_dir/$FILENAME"

        if [ -f "$FILEPATH" ]; then
            if check_whitelist "$FILENAME"; then
                echo "[$label] Waiting ${SCAN_SETTLE_TIME}s to settle..."
                sleep "$SCAN_SETTLE_TIME"

                if [ ! -f "$FILEPATH" ]; then
                    echo "[$label] File disappeared during wait. Skipping."
                    continue
                fi

                if upload_to_paperless "$FILEPATH" "$api_key" "$tags"; then
                    if [ "$ARCHIVE" = "true" ]; then
                        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                        mv "$FILEPATH" "$archive_dir/${TIMESTAMP}_$FILENAME"
                        echo "[$label] Archived."
                    else
                        rm "$FILEPATH"
                        echo "[$label] Deleted."
                    fi
                else
                    echo "[$label] Upload failed — keeping file for retry."
                fi
            else
                echo "[$label] Skipped (not in whitelist): $FILENAME"
            fi
        fi
    done
}

# --- Samba runtime directories ---
mkdir -p /home/appuser/samba/private \
         /home/appuser/samba/var/locks \
         /home/appuser/samba/var/cache \
         /home/appuser/samba/var/run

# --- Global smb.conf header (shared by single-user and multi-user modes) ---
# smbd listens on an unprivileged internal port; the well-known SMB port 445
# is published externally via the compose port mapping (445:8445), so this
# container never needs any Linux capability to bind it.
cat > "$SMB_CONF" <<SMBEOF
[global]
   workgroup = WORKGROUP
   server string = Scanner Share
   security = user
   map to guest = Bad User
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   smb ports = 8445
   log level = 1
   username map = $SMB_USERMAP
   private dir = /home/appuser/samba/private
   lock directory = /home/appuser/samba/var/locks
   pid directory = /home/appuser/samba/var/run
   state directory = /home/appuser/samba/var/locks
   cache directory = /home/appuser/samba/var/cache
   ncalrpc dir = /home/appuser/samba/var/locks
   log file = /home/appuser/samba/var/log.%m

SMBEOF

: > "$SMB_USERMAP"

if [ -f "$USERS_CONFIG" ]; then
    # =====================================================
    # MULTI-USER MODE
    # =====================================================
    # Each configured user is mapped (via Samba's `username map`) onto one
    # of the fixed pool of Unix accounts baked into the image at build time
    # (smbuser01..smbuserNN), so Samba's tdbsam backend has an
    # NSS-resolvable account to attach a password to -- without ever
    # creating a Unix account at runtime, which would require root.
    echo "[INIT] Multi-user mode: reading $USERS_CONFIG"
    check_conf_perms "$USERS_CONFIG"

    user_count=0
    idx=1
    while IFS=: read -r u_user u_pass u_share u_api_key u_tags || [ -n "$u_user" ]; do
        # Strip inline comments and whitespace
        u_user="${u_user%%#*}"
        u_user="${u_user//[[:space:]]/}"
        [ -z "$u_user" ] && continue

        # Validate required fields
        if [ -z "$u_pass" ] || [ -z "$u_share" ] || [ -z "$u_api_key" ]; then
            echo "[WARN] Skipping incomplete entry for user '$u_user' (need password, share, api_key)"
            continue
        fi

        # Reject anything that isn't a plain identifier -- prevents path
        # traversal via /data/$u_user and smb.conf stanza injection via
        # [$u_share].
        if ! [[ "$u_user" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
            echo "[WARN] Skipping invalid username '$u_user' (letters, digits, '_'/'-' only; must start with a letter)"
            continue
        fi
        if ! [[ "$u_share" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
            echo "[WARN] Skipping user '$u_user': invalid share name '$u_share' (letters, digits, '_'/'-' only; must start with a letter)"
            continue
        fi

        if [ "$idx" -gt "$SMB_POOL_SIZE" ]; then
            echo "[WARN] Skipping user '$u_user': Samba account pool exhausted (SMB_POOL_SIZE=$SMB_POOL_SIZE). Rebuild the image with --build-arg SMB_POOL_SIZE=<larger> to support more users."
            continue
        fi
        slot=$(printf "smbuser%02d" "$idx")
        idx=$((idx + 1))

        echo "[INIT] Configuring user: $u_user (share: $u_share, slot: $slot)"

        # Set the Samba password first. Only on success do we wire up
        # directories, the username map entry, the share stanza, and the
        # watcher -- a user never ends up with a share defined but no
        # working credential.
        if ! printf '%s\n%s\n' "$u_pass" "$u_pass" | pdbedit --configfile "$SMB_CONF" -a -u "$slot" -t >/dev/null 2>&1 && \
           ! printf '%s\n%s\n' "$u_pass" "$u_pass" | pdbedit --configfile "$SMB_CONF" -r -u "$slot" -t >/dev/null 2>&1; then
            echo "[ERROR] Failed to set Samba password for '$u_user' (slot $slot) — skipping this user's share and watcher." >&2
            continue
        fi

        mkdir -p "/data/$u_user/inbox" "/data/$u_user/archive"

        echo "$slot = $u_user" >> "$SMB_USERMAP"

        cat >> "$SMB_CONF" <<SMBEOF

[$u_share]
   path = /data/$u_user/inbox
   comment = Scanner inbox for $u_user
   valid users = $slot
   force user = appuser
   writable = yes
   browsable = yes
   create mask = 0660
   directory mask = 0770
SMBEOF

        watch_inbox "$u_user" "/data/$u_user/inbox" "/data/$u_user/archive" "$u_api_key" "${u_tags:-}" &

        user_count=$((user_count + 1))
    done < "$USERS_CONFIG"

    if [ "$user_count" -eq 0 ]; then
        echo "[ERROR] No valid, working users configured from $USERS_CONFIG" >&2
        exit 1
    fi

    echo "[INFO] Configured and started $user_count user(s)."

else
    # =====================================================
    # SINGLE-USER (LEGACY) MODE
    # =====================================================
    if [ -z "${PAPERLESS_API_KEY:-}" ]; then
        echo "[ERROR] No $USERS_CONFIG found and PAPERLESS_API_KEY is not set."
        echo "[ERROR] Either mount a users.conf or set PAPERLESS_API_KEY in your .env"
        exit 1
    fi

    SMB_USER_VAL="${SMB_USER:-scanner}"
    SMB_PASS_VAL="${SMB_PASSWORD:-scan123}"
    SMB_SHARE_VAL="${SMB_SHARE:-scanner}"

    if [ "$SMB_PASS_VAL" = "scan123" ]; then
        echo "[WARN] Using the DEFAULT SMB password 'scan123'. This is an example value only — change SMB_PASSWORD in .env before exposing this container to any network." >&2
    fi

    echo "[INIT] Single-user mode: SMB user '$SMB_USER_VAL', share '$SMB_SHARE_VAL'"

    mkdir -p /data/inbox /data/archive

    echo "appuser = $SMB_USER_VAL" > "$SMB_USERMAP"

    cat >> "$SMB_CONF" <<SMBEOF
[$SMB_SHARE_VAL]
   path = /data/inbox
   comment = Place Scans Here
   valid users = appuser
   force user = appuser
   writable = yes
   browsable = yes
   create mask = 0660
   directory mask = 0770
SMBEOF

    if ! printf '%s\n%s\n' "$SMB_PASS_VAL" "$SMB_PASS_VAL" | pdbedit --configfile "$SMB_CONF" -a -u appuser -t >/dev/null 2>&1 && \
       ! printf '%s\n%s\n' "$SMB_PASS_VAL" "$SMB_PASS_VAL" | pdbedit --configfile "$SMB_CONF" -r -u appuser -t >/dev/null 2>&1; then
        echo "[ERROR] Failed to set Samba password for '$SMB_USER_VAL'." >&2
        exit 1
    fi

    echo "[CONFIG] SMB Share: $SMB_SHARE_VAL"
    watch_inbox "$SMB_USER_VAL" "/data/inbox" "/data/archive" "$PAPERLESS_API_KEY" "${PAPERLESS_TAGS:-}" &
fi

# --- Start Samba ---
echo "[INFO] Starting smbd on internal port 8445 (published externally as 445)..."
smbd -F -s "$SMB_CONF" --no-process-group < /dev/null &
SAMBA_PID=$!

# Graceful shutdown: kill all background jobs when smbd exits or SIGTERM received
cleanup() {
    echo "[INFO] Shutting down..."
    kill "$(jobs -p)" 2>/dev/null || true
    wait
}
trap cleanup TERM INT

wait $SAMBA_PID
