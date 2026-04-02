FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    rsync \
    util-linux \
    p7zip-full \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY watcher.sh /app/watcher.sh

RUN chmod +x /app/watcher.sh

CMD ["/app/watcher.sh"]
