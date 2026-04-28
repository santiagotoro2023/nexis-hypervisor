#!/bin/bash
set -e

INSTALL_DIR=/opt/nexis-hypervisor

# Stop existing service
systemctl stop nexis-hypervisor-daemon 2>/dev/null || true

# Fix permissions
chown -R root:root "${INSTALL_DIR}"
chmod +x "${INSTALL_DIR}/daemon/main.py" 2>/dev/null || true

# Activate and upgrade venv in-place (handles version bumps)
if [ -f "${INSTALL_DIR}/venv/bin/pip" ]; then
    "${INSTALL_DIR}/venv/bin/pip" install --quiet --upgrade pip
    "${INSTALL_DIR}/venv/bin/pip" install --quiet -r "${INSTALL_DIR}/daemon/requirements.txt"
fi

# Reload systemd and enable the service
systemctl daemon-reload
systemctl enable nexis-hypervisor-daemon
systemctl start nexis-hypervisor-daemon

echo "NeXiS Hypervisor installed. Access at https://<host-ip>:8443"
