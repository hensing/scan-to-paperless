# scan-to-paperless
FROM alpine:3.24

# Number of pre-provisioned Samba "pool" accounts available for multi-user
# mode. Each configured user in users.conf is mapped (via Samba's
# `username map`) onto one of these accounts at container start, so that
# Samba's tdbsam backend has an NSS-resolvable Unix account to attach a
# password to, without ever creating Unix accounts at runtime (which would
# require root). Rebuild with a larger value if you need more than this many
# simultaneous users.
ARG SMB_POOL_SIZE=32
ENV SMB_POOL_SIZE=${SMB_POOL_SIZE}

# Fixed UID/GID the container always runs as. Default follows the
# "distroless nonroot" convention (65532) rather than 1000, specifically to
# avoid colliding with a real interactive/sudo-capable host user -- Docker
# does not remap UIDs into a separate namespace by default, so "UID 1000 in
# the container" is literally the same UID as a host account, which is
# often the operator's own login on single-user Debian/Raspberry Pi OS
# hosts. Override at build time (e.g. --build-arg APP_UID=1000
# --build-arg APP_GID=1000) to match your own host user instead, if you'd
# rather avoid the one-time chown than avoid the UID collision.
ARG APP_UID=65532
ARG APP_GID=65532

# Install required packages
RUN apk add --no-cache \
    samba \
    samba-common-tools \
    inotify-tools \
    bash \
    tzdata \
    curl

# Create the app user/group and a fixed pool of login-disabled Samba
# accounts (smbuser01..smbuserNN) at build time. The container always runs
# as appuser (UID/GID APP_UID/APP_GID) -- there is no runtime UID/GID
# remapping.
RUN addgroup -g "${APP_GID}" appgroup && \
    adduser -u "${APP_UID}" -G appgroup -h /home/appuser -D appuser && \
    i=1; while [ "$i" -le "${SMB_POOL_SIZE}" ]; do \
        slot=$(printf "smbuser%02d" "$i"); \
        adduser -D -H -G appgroup "$slot"; \
        i=$((i + 1)); \
    done

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

RUN mkdir -p /data/inbox /data/archive /var/lib/samba /var/log/samba /run/samba /config \
    && chown -R appuser:appgroup /app /data /var/lib/samba /var/log/samba /run/samba /home/appuser \
    && chmod 755 /config

# smbd listens on an unprivileged port internally; the well-known SMB port
# 445 is published externally via compose's port mapping (445:8445), so no
# Linux capabilities are required to run this image.
EXPOSE 8445

USER appuser

ENTRYPOINT ["/app/entrypoint.sh"]
