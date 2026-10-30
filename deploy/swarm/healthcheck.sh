#!/bin/bash
set -eu
# The runtime image has bash but no curl: liveness check of /healthz via HTTP/1.1 on the container port.
exec 3<>/dev/tcp/127.0.0.1/8080
printf 'GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
IFS= read -r status <&3
exec 3>&-
[[ "$status" == *' 200 '* ]]
