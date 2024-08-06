FROM alpine:3.20
COPY zig-out/linux/bin/http-tunnel /app
ENTRYPOINT ["/app"]
