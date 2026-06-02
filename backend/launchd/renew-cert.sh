#!/usr/bin/env bash
# Renew the Tailscale TLS cert and bounce the backend so uvicorn picks it up.
#
# Invoked by dev.finklea.harnessvoice.cert-renew.plist on a 30-day cadence.
# Safe to run manually any time:
#   bash backend/launchd/renew-cert.sh

set -euo pipefail

DOMAIN="scadrial.tailceb58.ts.net"
TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
TAILSCALE_CERT_DIR="$HOME/Library/Containers/io.tailscale.ipn.macos/Data"
DEST_DIR="$HOME/.config/tailscale-certs"
BACKEND_LABEL="dev.finklea.harnessvoice.backend"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "[$TIMESTAMP] starting cert renewal for $DOMAIN"

if [ ! -x "$TAILSCALE" ]; then
    echo "[$TIMESTAMP] ERROR: tailscale binary not found at $TAILSCALE" >&2
    exit 1
fi

# `tailscale cert` is idempotent — re-running renews if the cert is within
# 30 days of expiry, otherwise no-ops.
if "$TAILSCALE" cert "$DOMAIN"; then
    echo "[$TIMESTAMP] cert renewal OK"
else
    echo "[$TIMESTAMP] cert renewal FAILED" >&2
    exit 1
fi

# Copy from Tailscale's app-sandboxed dir into a non-sandboxed location.
# Symlinks won't do — uvicorn's TLS load via the symlink triggers
# InterruptedError [Errno 4] on macOS because the sandboxed source dir
# raises a signal during the cross-container read.
mkdir -p "$DEST_DIR"
cp "$TAILSCALE_CERT_DIR/$DOMAIN.crt" "$DEST_DIR/scadrial.crt"
cp "$TAILSCALE_CERT_DIR/$DOMAIN.key" "$DEST_DIR/scadrial.key"
chmod 644 "$DEST_DIR/scadrial.crt"
chmod 600 "$DEST_DIR/scadrial.key"
echo "[$TIMESTAMP] cert copied to $DEST_DIR"

# Bounce the backend so uvicorn re-reads the cert files. launchctl kickstart
# stops the service if running, then restarts it — safer than HUP because
# uvicorn doesn't reload TLS in-place.
if launchctl print "gui/$(id -u)/$BACKEND_LABEL" >/dev/null 2>&1; then
    echo "[$TIMESTAMP] restarting backend to pick up new cert"
    launchctl kickstart -k "gui/$(id -u)/$BACKEND_LABEL"
else
    echo "[$TIMESTAMP] backend LaunchAgent not loaded; skipping restart"
fi

echo "[$TIMESTAMP] done"
