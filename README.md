# unattended-upgrades-setup

A fully automated shell script to configure `unattended-upgrades` on Debian/Ubuntu systems.

## Features

- Ensures all required packages are installed
- Safe by creating backups and supporting rollback
- Supports dry-run verification
- Enables systemd timers for automatic execution
- Optional email alerts

## Usage

```bash
sudo ./src/unattended-setup.sh
```

