#!/bin/bash
# scan-to-paperless entrypoint
# Author: Dr. Henning Dickten (@hensing)

set -e

USERS_CONFIG=${USERS_CONFIG:-"/config/users.conf"}
SMB_CONF="/tmp/smb.conf"

# =========================================================
# ROOT SETUP PHASE
# =========================================================
if [ "$(id -u)" = "0" ]; then

    TARGET_UID=${PUID:-1000}
    TARGET_GID=${PGID:-1000}
    echo "[INIT] Setting up user with PUID: $TARGET_UID and PGID: $TARGET_GID"
    groupmod -o -g "$TARGET_GID" appgroup
    usermod -o -u "$TARGET_UID" -g "$TARGET_GID" appuser

    # Prepare Samba runtime directories
    mkdir -p /home/appuser/samba/private \
             /home/appuser/samba/var/locks \
             /home/appuser/samba/var/cache \
             /home/appuser/samba/var/run

    if [ -f "$USERS_CONFIG" ]; then
        # -------------------------------------------------------
        # MULTI-USER MODE
        # -------------------------------------------------------
        echo "[INIT] Multi-user mode: reading $USERS_CONFIG"

        # Write global smb.conf header (no username map in multi-user mode)
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
   smb ports = 445
   log level = 1
   private dir = /home/appuser/samba/private
   lock directory = /home/appuser/samba/var/locks
   pid directory = /home/appuser/samba/var/run
   state directory = /home/appuser/samba/var/locks
   cache directory = /home/appuser/samba/var/cache
   ncalrpc dir = /home/appuser/samba/var/locks
   log file = /home/appuser/samba/var/log.%m

SMBEOF

        user_count=0
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

            echo "[INIT] Configuring user: $u_user (share: $u_share)"

            # Create ghost Linux user for pdbedit (no login, no home)
            if ! id "$u_user" &>/dev/null; then
                adduser -D -H -G appgroup "$u_user"
                echo "[INIT] Created Linux user: $u_user"
            fi

            # Create per-user directories
            mkdir -p "/data/$u_user/inbox" "/data/$u_user/archive"

            # Append share stanza to smb.conf
            cat >> "$SMB_CONF" <<SMBEOF
[$u_share]
   path = /data/$u_user/inbox
   comment = Scanner inbox for $u_user
   valid users = $u_user
   force user = appuser
   writable = yes
   browsable = yes
   create mask = 0660
   directory mask = 0770

SMBEOF

            # Add Samba password (requires root, done here before privilege drop)
            echo "[INIT] Setting Samba password for: $u_user"
            printf '%s\n%s\n' "$u_pass" "$u_pass" | \
                pdbedit --configfile "$SMB_CONF" -a -u "$u_user" -t 2>/dev/null || \
            printf '%s\n%s\n' "$u_pass" "$u_pass" | \
                pdbedit --configfile "$SMB_CONF" -r -u "$u_user" -t 2>/dev/null || true

            user_count=$((user_count + 1))
        done < "$USERS_CONFIG"

        if [ "$user_count" -eq 0 ]; then
            echo "[ERROR] No valid users found in $USERS_CONFIG"
            exit 1
        fi

        echo "[INIT] Configured $user_count user(s)."

    else
        # -------------------------------------------------------
        # SINGLE-USER (LEGACY) MODE
        # -------------------------------------------------------
        if [ -z "${PAPERLESS_API_KEY:-}" ]; then
            echo "[ERROR] No $USERS_CONFIG found and PAPERLESS_API_KEY is not set."
            echo "[ERROR] Either mount a users.conf or set PAPERLESS_API_KEY in your .env"
            exit 1
        fi

        SMB_USER_VAL="${SMB_USER:-scanner}"
        SMB_PASS_VAL="${SMB_PASSWORD:-scan123}"
        SMB_SHARE_VAL="${SMB_SHARE:-scanner}"
        SMB_USERMAP="/tmp/usermap"

        echo "[INIT] Single-user mode: SMB user '$SMB_USER_VAL', share '$SMB_SHARE_VAL'"

        mkdir -p /data/inbox /data/archive

        echo "appuser = $SMB_USER_VAL" > "$SMB_USERMAP"

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
   smb ports = 445
   log level = 1
   username map = $SMB_USERMAP
   private dir = /home/appuser/samba/private
   lock directory = /home/appuser/samba/var/locks
   pid directory = /home/appuser/samba/var/run
   state directory = /home/appuser/samba/var/locks
   cache directory = /home/appuser/samba/var/cache
   ncalrpc dir = /home/appuser/samba/var/locks
   log file = /home/appuser/samba/var/log.%m

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

        printf '%s\n%s\n' "$SMB_PASS_VAL" "$SMB_PASS_VAL" | \
            pdbedit --configfile "$SMB_CONF" -a -u appuser -t 2>/dev/null || \
        printf '%s\n%s\n' "$SMB_PASS_VAL" "$SMB_PASS_VAL" | \
            pdbedit --configfile "$SMB_CONF" -r -u appuser -t 2>/dev/null || true
    fi

    # Fix ownership
    chown -R appuser:appgroup /data /home/appuser

    echo "[INIT] Dropping privileges to appuser..."
    exec su-exec appuser "$0" --run
fi

# =========================================================
# SERVICE PHASE (running as appuser)
# =========================================================
[ "$1" != "--run" ] && { echo "[ERROR] Unexpected invocation. Use the Docker entrypoint."; exit 1; }

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

    if curl "${curl_opts[@]}" \
          --max-time "$UPLOAD_TIMEOUT" \
          -X POST \
          -H "Authorization: Token $api_key" \
          "${curl_form[@]}" \
          "$PAPERLESS_URL/api/documents/post_document/"; then
        echo "[SUCCESS] Upload complete: $filename"
        return 0
    else
        echo "[ERROR] Upload failed: $filename"
        return 1
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

# --- Start Watchers ---

if [ -f "$USERS_CONFIG" ]; then
    # Multi-user mode: one watcher per user
    watcher_count=0
    while IFS=: read -r u_user u_pass u_share u_api_key u_tags || [ -n "$u_user" ]; do
        u_user="${u_user%%#*}"
        u_user="${u_user//[[:space:]]/}"
        [ -z "$u_user" ] && continue
        [ -z "$u_pass" ] || [ -z "$u_share" ] || [ -z "$u_api_key" ] && continue

        watch_inbox "$u_user" "/data/$u_user/inbox" "/data/$u_user/archive" "$u_api_key" "${u_tags:-}" &
        watcher_count=$((watcher_count + 1))
    done < "$USERS_CONFIG"
    echo "[INFO] Started $watcher_count watcher(s)."
else
    # Single-user mode
    u="${SMB_USER:-scanner}"
    echo "[CONFIG] SMB Share: ${SMB_SHARE:-scanner}"
    watch_inbox "$u" "/data/inbox" "/data/archive" "$PAPERLESS_API_KEY" "${PAPERLESS_TAGS:-}" &
fi

# --- Start Samba ---
echo "[INFO] Starting smbd on port 445..."
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
