#!/bin/sh
set -eu

case "$1" in
  remove|purge|abort-install|abort-upgrade)
    rm -f -- /opt/codex-bridge/.package-maintenance
    ;;
esac
