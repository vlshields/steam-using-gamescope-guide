#!/bin/bash

# Enable strict error handling
set -euo pipefail
trap 'error_handler $? $LINENO' ERR

# Configuration
SCRIPT_PERMISSIONS="755"
SESSION_FILE_PERMISSIONS="644"
STEAMOS_POLKIT_HELPERS_DIR="steamos-polkit-helpers"
USR_BIN_DIR="/usr/bin"
WAYLAND_SESSIONS_DIR="/usr/share/wayland-sessions"

# Logging setup
LOG_FILE="/var/log/steam-gamescope-installer.log"
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

# Error handler for rollback
error_handler() {
    local exit_code=$1
    local line_number=$2
    log "ERROR" "Script failed with exit code $exit_code at line $line_number"
    log "INFO" "Starting rollback..."
    rollback
    exit "$exit_code"
}

# Rollback function
rollback() {
    log "INFO" "Rolling back changes..."
    
    # Track what was installed for rollback
    if [ -f "/tmp/gamescope_install_tracker" ]; then
        while IFS= read -r file; do
            if [ -f "$file" ]; then
                rm -f "$file"
                log "INFO" "Removed: $file"
            elif [ -d "$file" ]; then
                # Only remove directory if it's empty and was created by us
                if [ -z "$(ls -A "$file" 2>/dev/null)" ]; then
                    rmdir "$file" 2>/dev/null || true
                    log "INFO" "Removed empty directory: $file"
                fi
            fi
        done < "/tmp/gamescope_install_tracker"
        rm -f "/tmp/gamescope_install_tracker"
    fi
    
    # Restore autologin if it was modified
    if [ -f "/tmp/autologin_backup" ]; then
        # shellcheck source=/dev/null
        source /tmp/autologin_backup
        if [ -n "${BACKUP_DM:-}" ] && [ -n "${USERNAME:-}" ]; then
            if [ -f "$USR_BIN_DIR/steamos-autologin" ]; then
                "$USR_BIN_DIR/steamos-autologin" disable "$USERNAME" 2>/dev/null || true
            fi
        fi
        rm -f "/tmp/autologin_backup"
    fi
    
    log "INFO" "Rollback completed"
}

# Function to track installed files
track_installation() {
    echo "$1" >> /tmp/gamescope_install_tracker
}

# Version checking function
check_version() {
    local command="$1"
    local min_version="$2"
    local current_version
    
    if ! command -v "$command" &> /dev/null; then
        log "ERROR" "$command is not installed"
        return 1
    fi
    
    case "$command" in
        gamescope)
            current_version=$(gamescope --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
            ;;
        steam)
            # Steam version is harder to get reliably
            if steam --version &>/dev/null; then
                current_version=$(steam --version 2>&1 | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "0.0.0.0")
            else
                log "WARN" "Could not determine Steam version, assuming it's compatible"
                return 0
            fi
            ;;
        *)
            log "WARN" "Unknown command for version check: $command"
            return 0
            ;;
    esac
    
    if [ -n "$current_version" ] && [ "$current_version" != "0.0.0" ]; then
        log "INFO" "$command version: $current_version (minimum required: $min_version)"
        # Simple version comparison (may need enhancement for complex versions)
        if [ "$(printf '%s\n' "$min_version" "$current_version" | sort -V | head -n1)" != "$min_version" ]; then
            log "ERROR" "$command version $current_version is below minimum required version $min_version"
            return 1
        fi
    fi
    return 0
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
    
    # Check if username is too long (Linux typically limits to 32 characters)
    if [ ${#username} -gt 32 ]; then
        log "ERROR" "Username is too long (maximum 32 characters)"
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        log "ERROR" "User '$username' does not exist"
        return 1
    fi
    
    log "DEBUG" "Username '$username' validated successfully"
    return 0
}

# Function to safely copy and track files
safe_copy() {
    local source="$1"
    local dest="$2"
    local perms="${3:-755}"
    
    if [ ! -f "$source" ]; then
        log "ERROR" "Source file does not exist: $source"
        return 1
    fi
    
    # Create parent directory if needed
    local parent_dir
    parent_dir=$(dirname "$dest")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir"
        track_installation "$parent_dir"
    fi
    
    # Copy file
    cp "$source" "$dest"
    chmod "$perms" "$dest"
    track_installation "$dest"
    log "DEBUG" "Installed: $dest (permissions: $perms)"
    
    return 0
}

# Main script starts here

# Check if the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Use 'sudo ./installer.sh'"
    exit 1
fi

# Initialize installation tracker
> /tmp/gamescope_install_tracker

# Start logging
log "INFO" "Starting Steam Gamescope installation - $(date)"
log "INFO" "Log file: $LOG_FILE"

# Get the username - first try to get the original user who ran sudo
USERNAME=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")

# If still root, ask for username
if [ "$USERNAME" = "root" ] || [ -z "$USERNAME" ]; then
    read -rp "Please enter the username of the primary user: " USERNAME
fi

# Validate username
if ! validate_username "$USERNAME"; then
    log "ERROR" "Invalid username provided. Exiting..."
    exit 1
fi

log "INFO" "Installing for user: $USERNAME"

# Check required software versions
log "INFO" "Checking required software versions..."

# Check gamescope (minimum version 3.11.0 for basic functionality)
if ! check_version "gamescope" "3.11.0"; then
    log "WARN" "Gamescope version check failed"
    read -rp "Continue anyway? (y/n): " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "INFO" "Installation cancelled by user"
        exit 1
    fi
fi

# Check steam
if ! command -v steam &> /dev/null; then
    log "WARN" "Steam is not installed. It will be required to run the gamescope session."
    read -rp "Continue anyway? (y/n): " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "INFO" "Installation cancelled by user"
        exit 1
    fi
fi

log "INFO" "Creating directories..."

# Create steamos-polkit-helpers directory
mkdir -p "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR"
track_installation "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR"

# Ensure wayland-sessions directory exists
mkdir -p "$WAYLAND_SESSIONS_DIR"

log "INFO" "Setting permissions on source files..."

# Ensure the scripts have the correct permissions set before copying
[ -f ".$USR_BIN_DIR/gamescope-session" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/gamescope-session"
[ -f ".$USR_BIN_DIR/jupiter-biosupdate" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/jupiter-biosupdate"
[ -f ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/jupiter-biosupdate" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/jupiter-biosupdate"
[ -f ".$USR_BIN_DIR/steamos-select-branch" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/steamos-select-branch"
[ -f ".$USR_BIN_DIR/steamos-session-select" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/steamos-session-select"
[ -f ".$USR_BIN_DIR/steamos-update" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/steamos-update"
[ -f ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-update" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-update"
[ -f ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-set-timezone" ] && chmod "$SCRIPT_PERMISSIONS" ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-set-timezone"
[ -f ".$WAYLAND_SESSIONS_DIR/steam.desktop" ] && chmod "$SESSION_FILE_PERMISSIONS" ".$WAYLAND_SESSIONS_DIR/steam.desktop"

log "INFO" "Installing scripts..."

# Install scripts with error checking
safe_copy ".$USR_BIN_DIR/gamescope-session" "$USR_BIN_DIR/gamescope-session" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/jupiter-biosupdate" "$USR_BIN_DIR/jupiter-biosupdate" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/jupiter-biosupdate" "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/jupiter-biosupdate" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/steamos-select-branch" "$USR_BIN_DIR/steamos-select-branch" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/steamos-session-select" "$USR_BIN_DIR/steamos-session-select" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/steamos-update" "$USR_BIN_DIR/steamos-update" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-update" "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-update" "$SCRIPT_PERMISSIONS"
safe_copy ".$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-set-timezone" "$USR_BIN_DIR/$STEAMOS_POLKIT_HELPERS_DIR/steamos-set-timezone" "$SCRIPT_PERMISSIONS"
safe_copy ".$WAYLAND_SESSIONS_DIR/steam.desktop" "$WAYLAND_SESSIONS_DIR/steam.desktop" "$SESSION_FILE_PERMISSIONS"

# Install steamos-autologin if it exists
if [ -f "./steamos-autologin" ]; then
    log "INFO" "Installing autologin helper..."
    safe_copy "./steamos-autologin" "$USR_BIN_DIR/steamos-autologin" "$SCRIPT_PERMISSIONS"
fi

# Ask user about autologin configuration
echo
read -rp "Do you want to enable autologin to the Steam gamescope session? (y/N) " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    # Save current autologin state for potential rollback
    {
        echo "USERNAME=$USERNAME"
        if command -v lightdm &> /dev/null; then
            echo "BACKUP_DM=lightdm"
        elif command -v sddm &> /dev/null; then
            echo "BACKUP_DM=sddm"
        elif command -v gdm &> /dev/null || command -v gdm3 &> /dev/null; then
            echo "BACKUP_DM=gdm"
        fi
    } > /tmp/autologin_backup
    
    # Use the new steamos-autologin script if available
    if [ -f "$USR_BIN_DIR/steamos-autologin" ]; then
        log "INFO" "Enabling autologin for user: $USERNAME"
        if "$USR_BIN_DIR/steamos-autologin" enable "$USERNAME"; then
            log "INFO" "Autologin configured successfully"
        else
            log "WARN" "Failed to configure autologin automatically"
            log "INFO" "Please configure autologin manually for your display manager"
        fi
    else
        log "WARN" "steamos-autologin script not found. Please configure autologin manually."
    fi
fi

# Clean up installation tracker on success
rm -f /tmp/gamescope_install_tracker
rm -f /tmp/autologin_backup

log "INFO" "Installation complete!"
echo
echo "Installation complete!"
echo
echo "To use Steam with Gamescope:"
echo "  1. Log out of your current session"
echo "  2. At the login screen, select 'Steam' as your session type"
echo "  3. Log in with your user account"
echo
echo "Note: You can switch back to your regular desktop session at any time"
echo "      by selecting it from the session menu at the login screen."
echo
echo "Installation log saved to: $LOG_FILE"

# Ask about reboot if autologin was configured
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    echo
    read -rp "Would you like to reboot now? (y/n): " REBOOT_REPLY
    if [[ "$REBOOT_REPLY" =~ ^[Yy]$ ]]; then
        log "INFO" "Rebooting system..."
        sleep 2
        reboot
    fi
fi