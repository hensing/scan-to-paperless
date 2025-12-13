# scan-to-paperless
FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    samba \
    samba-common-tools \
    inotify-tools \
    bash \
    shadow \
    tzdata \
    curl \
    su-exec \
    libcap

# Create User and Group (Default ID 1000)
# IDs will be adjusted in entrypoint if PUID/PGID are set
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -h /home/appuser -D appuser

# Grant capability to bind privileged ports (445) as non-root
RUN setcap 'cap_net_bind_service=+ep' /usr/sbin/smbd

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

RUN mkdir -p /data/inbox /data/archive /var/lib/samba /var/log/samba /run/samba \
    && chown -R appuser:appgroup /app /data /var/lib/samba /var/log/samba /run/samba

EXPOSE 445

ENTRYPOINT ["/app/entrypoint.sh"]