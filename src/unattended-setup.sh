#!/bin/bash
set -euo pipefail  # Verbesserte Fehlerbehandlung

# Farben
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

log() {
    echo -e "${YELLOW}[*] $1${RESET}"
}

success() {
    echo -e "${GREEN}[✓] $1${RESET}"
}

error() {
    echo -e "${RED}[✗] $1${RESET}" >&2
}

info() {
    echo -e "${BLUE}[i] $1${RESET}"
}

# Pfade
CONFIG_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
PERIODIC="/etc/apt/apt.conf.d/10periodic"
BACKUP_DIR="/root/unattended-upgrades-backup-$(date +%Y%m%d-%H%M%S)"

# Root-Rechte prüfen
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Dieses Skript muss als root ausgeführt werden!"
        error "Verwenden Sie: sudo $0"
        exit 1
    fi
}

# Backup erstellen
create_backup() {
    log "Erstelle Backup in $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    [[ -f "$CONFIG_FILE" ]] && cp "$CONFIG_FILE" "$BACKUP_DIR/" 2>/dev/null || true
    [[ -f "$PERIODIC" ]] && cp "$PERIODIC" "$BACKUP_DIR/" 2>/dev/null || true

    success "Backup erstellt"
}

# Package Installation
install_packages() {
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        success "unattended-upgrades ist bereits installiert."
        return 0
    fi

    log "Aktualisiere Paket-Liste..."
    if ! apt update; then
        error "apt update fehlgeschlagen"
        return 1
    fi

    log "Installiere unattended-upgrades..."
    if apt install -y unattended-upgrades apt-listchanges bsd-mailx; then
        success "Installation erfolgreich"
        return 0
    else
        error "Installation fehlgeschlagen"
        return 1
    fi
}

# Konfiguration erstellen/reparieren
configure_main_config() {
    log "Konfiguriere Hauptdatei: $CONFIG_FILE"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ -f "/usr/share/unattended-upgrades/50unattended-upgrades" ]]; then
            cp "/usr/share/unattended-upgrades/50unattended-upgrades" "$CONFIG_FILE"
        else
            error "Template-Datei nicht gefunden"
            return 1
        fi
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup"
    local temp_file=$(mktemp)

    grep -v "distro_codename.*-security\|distro_codename.*-updates" "$CONFIG_FILE" > "$temp_file" || true

    if grep -q "Allowed-Origins" "$temp_file"; then
        sed -i '/Allowed-Origins {/a \        "${distro_id}:${distro_codename}-security";' "$temp_file"
        sed -i '/Allowed-Origins {/a \        "${distro_id}:${distro_codename}-updates";' "$temp_file"
    else
        error "Allowed-Origins Sektion nicht gefunden"
        rm -f "$temp_file"
        return 1
    fi

    grep -v "Unattended-Upgrade::Automatic-Reboot" "$temp_file" > "${temp_file}.tmp" || true
    mv "${temp_file}.tmp" "$temp_file"

    cat >> "$temp_file" << 'EOF'

// Automatische Reboots
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// E-Mail Benachrichtigungen (optional)
// Unattended-Upgrade::Mail "admin@localhost";
// Unattended-Upgrade::MailOnlyOnError "true";

// Remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Logging
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
EOF

    mv "$temp_file" "$CONFIG_FILE"
    success "Hauptkonfiguration aktualisiert"
}

# Periodic-Konfiguration
configure_periodic() {
    log "Konfiguriere Periodic-Datei: $PERIODIC"

    [[ -f "$PERIODIC" ]] && cp "$PERIODIC" "${PERIODIC}.backup"

    cat > "$PERIODIC" << 'EOF'
// Automatische Updates Konfiguration
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";

// Zusätzliche Optionen
APT::Periodic::Verbose "1";
APT::Periodic::CleanInterval "7";
EOF

    success "Periodic-Konfiguration gesetzt"
}

# Systemd Timer prüfen und aktivieren
configure_systemd() {
    log "Prüfe systemd Timer..."

    if systemctl is-enabled apt-daily.timer >/dev/null 2>&1; then
        success "apt-daily.timer ist bereits aktiviert"
    else
        systemctl enable apt-daily.timer
        success "apt-daily.timer aktiviert"
    fi

    if systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
        success "apt-daily-upgrade.timer ist bereits aktiviert"  
    else
        systemctl enable apt-daily-upgrade.timer
        success "apt-daily-upgrade.timer aktiviert"
    fi

    systemctl start apt-daily.timer apt-daily-upgrade.timer
    success "Timer gestartet"
}

# Verbesserter Testlauf
test_configuration() {
    log "Führe Konfigurationstest durch..."

    if ! apt-config dump | grep -q "Unattended-Upgrade"; then
        error "Konfigurationsdatei wird nicht korrekt gelesen"
        return 1
    fi

    info "Führe Dry-Run Test durch (kann 30-60 Sekunden dauern)..."
    local test_output
    if test_output=$(unattended-upgrade --dry-run --debug 2>&1); then
        if echo "$test_output" | grep -qi "Packages that will be upgraded\|Packages that would be upgraded\|Checking"; then
            success "Dry-Run Test erfolgreich"
            info "Testlauf-Details:"
            echo "$test_output" | grep -E "(Packages that|Checking|Initial blacklisted)" | head -5
            return 0
        else
            error "Dry-Run ergab keine erwarteten Ergebnisse"
            info "Debug-Ausgabe:"
            echo "$test_output" | tail -10
            return 1
        fi
    else
        error "Dry-Run Test fehlgeschlagen"
        echo "$test_output" | tail -10
        return 1
    fi
}

# Status anzeigen
show_status() {
    info "=== SYSTEMSTATUS ==="
    echo "Timer Status:"
    systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager -l | grep -E "(Active|Trigger)"

    echo -e "\nNächste geplante Ausführung:"
    systemctl list-timers apt-daily\* --no-pager

    echo -e "\nKonfigurationsdateien:"
    echo "  $CONFIG_FILE: $(test -f "$CONFIG_FILE" && echo "✓ vorhanden" || echo "✗ fehlt")"
    echo "  $PERIODIC: $(test -f "$PERIODIC" && echo "✓ vorhanden" || echo "✗ fehlt")"
}

# Rollback-Funktion
rollback() {
    error "Führe Rollback durch..."

    if [[ -f "${CONFIG_FILE}.backup" ]]; then
        mv "${CONFIG_FILE}.backup" "$CONFIG_FILE"
        log "Hauptkonfiguration zurückgesetzt"
    fi

    if [[ -f "${PERIODIC}.backup" ]]; then
        mv "${PERIODIC}.backup" "$PERIODIC"
        log "Periodic-Konfiguration zurückgesetzt"
    fi

    error "Rollback abgeschlossen"
}

main() {
    info "=== Unattended-Upgrades Setup-Skript ==="
    info "Dieses Skript konfiguriert automatische Updates für Ubuntu/Debian"
    echo

    check_root
    create_backup

    if ! install_packages; then
        error "Installation fehlgeschlagen"
        exit 1
    fi

    if ! configure_main_config; then
        error "Hauptkonfiguration fehlgeschlagen"
        rollback
        exit 1
    fi

    if ! configure_periodic; then
        error "Periodic-Konfiguration fehlgeschlagen"
        rollback
        exit 1
    fi

    configure_systemd

    if ! test_configuration; then
        error "Konfigurationstest fehlgeschlagen"
        rollback
        exit 1
    fi

    show_status

    success "✅ unattended-upgrades wurde erfolgreich konfiguriert!"
    info "Backup wurde erstellt in: $BACKUP_DIR"
    info "Logs können eingesehen werden mit: journalctl -u apt-daily"
}

main "$@"
