#!/bin/bash
# scan-to-paperless entrypoint
# Author: Dr. Henning Dickten (@hensing)

set -e

# --- 0. Fix Permissions & Drop Privileges ---
# Running as root initially
if [ "$(id -u)" = "0" ]; then
    
    # Read PUID and PGID from environment, default to 1000
    TARGET_UID=${PUID:-1000}
    TARGET_GID=${PGID:-1000}

    echo "[INIT] Setting up user with PUID: $TARGET_UID and PGID: $TARGET_GID"

    # Update internal user 'appuser' to match requested PUID/PGID
    # We use -o to allow non-unique IDs if necessary
    groupmod -o -g "$TARGET_GID" appgroup
    usermod -o -u "$TARGET_UID" -g "$TARGET_GID" appuser

    echo "[INIT] Fixing permissions on /data and /home/appuser..."
    
    # Ensure directories exist
    mkdir -p /data/inbox /data/archive
    
    # Fix ownership for data volume
    chown -R appuser:appgroup /data
    
    # Ensure home directory structure for Samba
    mkdir -p /home/appuser/samba
    chown -R appuser:appgroup /home/appuser

    echo "[INIT] Dropping privileges to appuser..."
    # Restart script as appuser (now with correct UID/GID)
    exec su-exec appuser "$0" "$@"
fi

# =========================================================
# RUNNING AS APPUSER BELOW THIS LINE
# =========================================================

# --- Set Defaults ---
SMB_USER=${SMB_USER:-"scanner"}
SMB_PASSWORD=${SMB_PASSWORD:-"scan123"}
SMB_SHARE=${SMB_SHARE:-"scanner"}
PAPERLESS_URL=${PAPERLESS_URL:-""}
PAPERLESS_API_KEY=${PAPERLESS_API_KEY:-""}
PAPERLESS_VERIFY_SSL=${PAPERLESS_VERIFY_SSL:-true}
PAPERLESS_TAGS=${PAPERLESS_TAGS:-""}
WHITELIST=${WHITELIST:-"pdf,jpg,png,bmp"}
ARCHIVE=${ARCHIVE:-true}
UPLOAD_TIMEOUT=${UPLOAD_TIMEOUT:-30}
SCAN_SETTLE_TIME=${SCAN_SETTLE_TIME:-5}

# Validate required variables
if [ -z "$PAPERLESS_URL" ] || [ -z "$PAPERLESS_API_KEY" ]; then
    echo "[ERROR] PAPERLESS_URL and PAPERLESS_API_KEY must be set in .env"
    exit 1
fi

echo "╔══════════════════════════════╗"
echo "║      SCAN TO PAPERLESS       ║"
echo "║     Dr. Henning Dickten      ║"
echo "║            2025              ║"
echo "╚══════════════════════════════╝"
echo "[CONFIG] Paperless URL: $PAPERLESS_URL"
echo "[CONFIG] SMB Share: $SMB_SHARE"
echo "[CONFIG] Archive: $ARCHIVE"
echo "[CONFIG] Whitelist: $WHITELIST"
echo "[CONFIG] Settle Time: ${SCAN_SETTLE_TIME}s"
echo "[CONFIG] User UID: $(id -u), GID: $(id -g)"

# --- 1. Samba Configuration ---
SMB_CONF="/tmp/smb.conf"
SMB_USERMAP="/tmp/usermap"

# Create Samba directories in User Home
mkdir -p /home/appuser/samba/private /home/appuser/samba/var/locks /home/appuser/samba/var/cache /home/appuser/samba/var/run

# Username map: map scanner to appuser
echo "appuser = $SMB_USER" > "$SMB_USERMAP"

cat > "$SMB_CONF" <<EOF
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

[$SMB_SHARE]
   path = /data/inbox
   comment = Place Scans Here
   valid users = appuser
   force user = appuser
   writable = yes
   browsable = yes
   create mask = 0660
   directory mask = 0770
EOF

# Setup Samba User
echo "[INIT] Setting up Samba user for appuser via pdbedit..."
echo -e "$SMB_PASSWORD\n$SMB_PASSWORD" | pdbedit --configfile "$SMB_CONF" -a -u appuser -t

# --- 2. Start Samba in Background ---
echo "[INFO] Starting smbd on port 445..."
smbd -F -s "$SMB_CONF" --no-process-group < /dev/null &
SAMBA_PID=$!

# --- 3. File Watcher & Upload Logic ---
echo "[INFO] Watching /data/inbox for new files..."

# Helper Functions
check_whitelist() {
    local filename="$1"
    local ext="${filename##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    IFS=',' read -ra EXT_ARRAY <<< "$WHITELIST"
    for allowed_ext in "${EXT_ARRAY[@]}"; do
        allowed_ext=$(echo "$allowed_ext" | tr '[:upper:]' '[:lower:]' | xargs)
        if [ "$ext" = "$allowed_ext" ]; then
            return 0
        fi
    done
    return 1
}

upload_to_paperless() {
    local filepath="$1"
    local filename=$(basename "$filepath")

    echo "[UPLOAD] Uploading $filename to Paperless-NGX..."

    local curl_opts=()
    if [ "$PAPERLESS_VERIFY_SSL" = "false" ]; then
        curl_opts+=("--insecure")
    fi

    local curl_form=("-F" "document=@$filepath")
    if [ -n "$PAPERLESS_TAGS" ]; then
        curl_form+=("-F" "tags=$PAPERLESS_TAGS")
    fi

    if curl "${curl_opts[@]}" \
          --max-time "$UPLOAD_TIMEOUT" \
          -X POST \
          -H "Authorization: Token $PAPERLESS_API_KEY" \
          "${curl_form[@]}" \
          "$PAPERLESS_URL/api/documents/post_document/"; then
        echo "[SUCCESS] Upload complete."
        return 0
    else
        echo "[ERROR] Upload failed."
        return 1
    fi
}

# Watcher Loop
inotifywait -m "/data/inbox" -e close_write -e moved_to --format '%f' | while read FILENAME; do
    echo "[DETECTED] New file: $FILENAME"
    FILEPATH="/data/inbox/$FILENAME"

    if [ -f "$FILEPATH" ]; then
        # 1. Check whitelist FIRST
        if check_whitelist "$FILENAME"; then

            # 2. Settle Time (Wait for write to finish completely)
            echo "[WAIT] Waiting ${SCAN_SETTLE_TIME}s for file to settle..."
            sleep "$SCAN_SETTLE_TIME"

            # Check if file still exists after sleep (race condition check)
            if [ ! -f "$FILEPATH" ]; then
                 echo "[INFO] File disappeared during wait time. Ignoring."
                 continue
            fi

            echo "[CHECK] File type allowed and settled."

            # 3. Upload
            if upload_to_paperless "$FILEPATH"; then
                # Handle post-upload
                if [ "$ARCHIVE" = "true" ]; then
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    mv "$FILEPATH" "/data/archive/${TIMESTAMP}_$FILENAME"
                    echo "[ARCHIVE] File moved to archive."
                else
                    rm "$FILEPATH"
                    echo "[DELETE] File deleted."
                fi
            else
                echo "[SKIP] Upload failed, keeping file in inbox for retry."
            fi
        else
            echo "[SKIP] File type not in whitelist ($WHITELIST), ignoring."
        fi
    fi
done &

# Keep container alive
wait $SAMBA_PID