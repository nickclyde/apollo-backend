#!/bin/sh
# No-op UDP sink for statsd. The Datadog client crashes if STATSD_URL is
# unreachable, but it doesn't care what's actually on the other end.
set -e
apk add --no-cache socat >/dev/null
exec socat -u udp-recv:8125 stdout
