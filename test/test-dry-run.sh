#!/bin/bash
# Testskript für Unattended-Upgrades im Dry-Run-Modus
set -euo pipefail

echo "[*] Starte Dry-Run Test für unattended-upgrade..."
unattended-upgrade --dry-run --debug

