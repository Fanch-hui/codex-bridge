#!/bin/sh
set -eu

case "$1" in
  configure|abort-upgrade|abort-remove|abort-deconfigure)
    rm -f -- /opt/codex-bridge/.package-maintenance
    ;;
esac
