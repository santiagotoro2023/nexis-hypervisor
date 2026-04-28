#!/bin/bash
set -e

case "$1" in
    remove)
        systemctl stop nexis-hypervisor-daemon 2>/dev/null || true
        systemctl disable nexis-hypervisor-daemon 2>/dev/null || true
        ;;
    purge)
        systemctl stop nexis-hypervisor-daemon 2>/dev/null || true
        systemctl disable nexis-hypervisor-daemon 2>/dev/null || true
        rm -rf /opt/nexis-hypervisor
        ;;
esac

systemctl daemon-reload 2>/dev/null || true
