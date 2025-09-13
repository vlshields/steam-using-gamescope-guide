#!/bin/bash

# Enable strict error handling
set -euo pipefail
trap 'error_handler $? $LINENO' ERR

# Configuration
STEAMOS_POLKIT_HELPERS_DIR="steamos-polkit-helpers"
USR_BIN_DIR="/usr/bin"
WAYLAND_SESSIONS_DIR="/usr/share/wayland-sessions"

# Logging setup
LOG_FILE="/var/log/steam-gamescope-uninstaller.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # Can be DEBUG, INFO, WARN, ERROR

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Also display to console with colors
    case "$level" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        DEBUG)
            if [ "$LOG_LEVEL" = "DEBUG" ]; then
                echo "[DEBUG] $message"
            fi
            ;;
    esac
}

# Error handler
error_handler() {
    local exit_code=$1
    local line_number=$2
    log "ERROR" "Script failed with exit code $exit_code at line $line_number"
    exit "$exit_code"
}

# Input validation function
validate_username() {
    local username="$1"
    
    # Check if username is empty
    if [ -z "$username" ]; then
        log "ERROR" "Username cannot be empty"
        return 1
    fi
    
    # Check if username contains only valid characters (alphanumeric, underscore, hyphen)
    if ! echo "$username" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        log "ERROR" "Username contains invalid characters. Only alphanumeric, underscore, and hyphen are allowed."
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        log "WARN" "User '$username' does not exist"
        # Don't fail on non-existent user during uninstall
        return 0
    fi
    
    return 0
}

# Function to safely remove files
safe_remove() {
    local file_path="$1"
    
    if [ -f "$file_path" ]; then
        rm -f "$file_path"
        log "INFO" "Removed: $file_path"
        return 0
    elif [ -d "$file_path" ]; then
        # Only remove directory if it's empty
        if [ -z "$(ls -A "$file_path" 2>/dev/null)" ]; then
            rmdir "$file_path" 2>/dev/null || true
            log "INFO" "Removed empty directory: $file_path"
        else
            log "WARN" "Directory not empty, skipping: $file_path"
        fi
        return 0
    else
        log "DEBUG" "File/directory not found, skipping: $file_path"
        return 0
    fi
}

# Check if the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Use 'sudo ./uninstaller.sh'"
    exit 1
fi

# Start logging
log "INFO" "Starting Steam Gamescope uninstallation - $(date)"
log "INFO" "Log file: $LOG_FILE"

# Get the username - first try to get the original user who ran sudo
USERNAME=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")

# If still root, ask for username
if [ "$USERNAME" = "root" ] || [ -z "$USERNAME" ]; then
    read -rp "Please enter the username of the primary user: " USERNAME
fi

# Validate username (won't fail on non-existent user)
validate_username "$USERNAME" || true

log "INFO" "Uninstalling for user: $USERNAME"
log "INFO" "Removing Steam Gamescope session files..."

# Remove scripts from /usr/bin
safe_remove "$USR_BIN_DIR/gamescope-session"
safe_remove "$USR_BIN_DIR/jupiter-biosupdate"
safe_remove "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/jupiter-biosupdate"
safe_remove "$USR_BIN_DIR/steamos-select-branch"
safe_remove "$USR_BIN_DIR/steamos-session-select"
safe_remove "$USR_BIN_DIR/steamos-update"
safe_remove "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-update"
safe_remove "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-set-timezone"

# Remove session file
safe_remove "$WAYLAND_SESSIONS_DIR/steam.desktop"

# Remove the steamos-polkit-helpers directory if empty
safe_remove "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR"

# Remove the steamos-autologin script
safe_remove "$USR_BIN_DIR/steamos-autologin"

# Ask about removing autologin configuration
echo
read -rp "Do you want to remove Steam gamescope autologin configuration? (y/N) " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    # Use the steamos-autologin script if available
    if [ -f ./steamos-autologin ]; then
        log "INFO" "Disabling autologin for user: $USERNAME"
        ./steamos-autologin disable "$USERNAME" || {
            log "WARN" "Failed to disable autologin using steamos-autologin script"
        }
    else
        # Fallback to manual removal if script is not available
        log "INFO" "steamos-autologin script not found, using manual removal"
        
        echo
        echo "Which display manager autologin should be removed?"
        echo "1) LightDM"
        echo "2) SDDM"
        echo "3) GDM/GDM3"
        echo "4) All of the above"
        echo "5) Skip autologin removal"
        echo
        read -rp "Enter your choice (1-5): " DM_CHOICE
        
        remove_lightdm_autologin() {
            # Remove LightDM autologin configuration
            if [ -f /etc/lightdm/lightdm.conf.d/50-gamescope-autologin.conf ]; then
                rm -f /etc/lightdm/lightdm.conf.d/50-gamescope-autologin.conf
                log "INFO" "Removed LightDM autologin configuration"
            fi
            
            # Remove user from autologin group if no other autologin configs exist
            if getent group autologin > /dev/null 2>&1; then
                if ! find /etc/lightdm/lightdm.conf.d/ -name "*autologin*" 2>/dev/null | grep -q .; then
                    gpasswd -d "$USERNAME" autologin 2>/dev/null || true
                    log "INFO" "Removed $USERNAME from autologin group"
                fi
            fi
        }
        
        remove_sddm_autologin() {
            # Remove SDDM autologin configuration
            if [ -f /etc/sddm.conf.d/autologin.conf ]; then
                rm -f /etc/sddm.conf.d/autologin.conf
                log "INFO" "Removed SDDM autologin configuration"
            fi
        }
        
        remove_gdm_autologin() {
            # Find GDM config path
            local GDM_CONF=""
            if [ -f /etc/gdm3/custom.conf ]; then
                GDM_CONF="/etc/gdm3/custom.conf"
            elif [ -f /etc/gdm/custom.conf ]; then
                GDM_CONF="/etc/gdm/custom.conf"
            fi
            
            if [ -n "$GDM_CONF" ] && [ -f "$GDM_CONF" ]; then
                # Backup before modifying
                if grep -q "^AutomaticLoginEnable=true" "$GDM_CONF"; then
                    local backup_file="${GDM_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                    cp "$GDM_CONF" "$backup_file"
                    log "INFO" "Backed up $GDM_CONF to $backup_file"
                    
                    # Disable autologin in GDM
                    sed -i 's/^AutomaticLoginEnable=true/AutomaticLoginEnable=false/' "$GDM_CONF"
                    sed -i 's/^AutomaticLogin=.*/AutomaticLogin=/' "$GDM_CONF"
                    log "INFO" "Disabled GDM autologin"
                fi
            fi
        }
        
        case "$DM_CHOICE" in
            1)
                remove_lightdm_autologin
                ;;
            2)
                remove_sddm_autologin
                ;;
            3)
                remove_gdm_autologin
                ;;
            4)
                log "INFO" "Removing all autologin configurations..."
                remove_lightdm_autologin
                remove_sddm_autologin
                remove_gdm_autologin
                ;;
            *)
                log "INFO" "Skipping autologin removal"
                ;;
        esac
    fi
fi

log "INFO" "Uninstallation complete!"
echo
echo "Uninstallation complete!"
echo "The Steam gamescope session has been removed from your system."

# Check for backup files
echo
BACKUP_FILES_FOUND=false
if ls /etc/lightdm/lightdm.conf.backup.* 2>/dev/null || \
   ls /etc/lightdm/lightdm.conf.d/*.backup.* 2>/dev/null || \
   ls /etc/sddm.conf.d/*.backup.* 2>/dev/null || \
   ls /etc/gdm*/custom.conf.backup.* 2>/dev/null; then
    BACKUP_FILES_FOUND=true
fi

if [ "$BACKUP_FILES_FOUND" = true ]; then
    echo "Backup configuration files were found:"
    ls -la /etc/lightdm/lightdm.conf.backup.* 2>/dev/null || true
    ls -la /etc/lightdm/lightdm.conf.d/*.backup.* 2>/dev/null || true
    ls -la /etc/sddm.conf.d/*.backup.* 2>/dev/null || true
    ls -la /etc/gdm*/custom.conf.backup.* 2>/dev/null || true
    echo
    echo "You can manually restore these if needed."
fi

echo
echo "Uninstallation log saved to: $LOG_FILE"