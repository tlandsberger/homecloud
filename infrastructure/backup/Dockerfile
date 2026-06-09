FROM restic/restic:0.19.0
RUN apk add --no-cache rclone
COPY entrypoint.sh /entrypoint.sh
COPY backup.sh /backup.sh
RUN chmod +x /entrypoint.sh /backup.sh
ENTRYPOINT ["/entrypoint.sh"]
