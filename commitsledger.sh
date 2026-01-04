#!/bin/bash

# ------------------------------------------------------------------
#  COMMITSLEDGER - SMART GIT SYNCHRONIZATION UTILITY
#  - Detects current branch
#  - Detects all remotes
#  - Calculates missing commits for each remote AUTOMATICALLY
#  - Supports dry-run, logging, and configuration
# ------------------------------------------------------------------

# Default configuration values
DRY_RUN=false
LOG_FILE=""
CONFIG_FILE="$HOME/.commitsledger.conf"
VERBOSE=false
PUSH_DELAY=0.5

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -n, --dry-run     Show what would be pushed without actually pushing"
    echo "  -v, --verbose     Enable verbose output"
    echo "  -c, --config FILE Use specified configuration file"
    echo "  -l, --log FILE    Write logs to specified file"
    echo "  -h, --help        Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run normally"
    echo "  $0 --dry-run          # Show what would be pushed"
    echo "  $0 --verbose --log /tmp/commitsledger.log  # Verbose logging"
}

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$VERBOSE" = true ]; then
        echo "[$timestamp] $message" >&2
    fi
    
    if [ -n "$LOG_FILE" ]; then
        echo "[$timestamp] $message" >> "$LOG_FILE"
    fi
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -l|--log)
                LOG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Function to load configuration from file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_message "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        log_message "Configuration file $CONFIG_FILE not found, using defaults"
    fi
}

# Function to validate git repository
validate_git_repo() {
    if [ ! -d .git ] && ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_message "ERROR: This directory is not a git repository."
        exit 1
    fi
}

# Function to get current branch
get_current_branch() {
    local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        log_message "ERROR: Unable to determine current branch."
        exit 1
    fi
    echo "$branch"
}

# Function to validate git connectivity
validate_git_connectivity() {
    local remote="$1"
    if ! git ls-remote "$remote" > /dev/null 2>&1; then
        log_message "ERROR: Cannot connect to remote '$remote'. Check authentication and network."
        return 1
    fi
    return 0
}

# Function to get commit count
get_commit_count() {
    local commits="$1"
    echo "$commits" | sed '/^$/d' | wc -l | xargs
}

# Function to get commit message
get_commit_message() {
    local commit_hash="$1"
    git log --format=%s -n 1 "$commit_hash" 2>/dev/null | cut -c1-50
}

# Function to validate remote name
validate_remote() {
    local remote="$1"
    if ! git remote | grep -q "^$remote$"; then
        log_message "ERROR: Remote '$remote' does not exist."
        return 1
    fi
    return 0
}

# Function to handle push errors
handle_push_error() {
    local remote="$1"
    local commit_hash="$2"
    log_message "ERROR: Failed to push ${commit_hash:0:7} to $remote"
    echo "Error pushing to $remote. Stopping operations for this remote."
}

# Function to sanitize input
sanitize_input() {
    local input="$1"
    # Remove potentially dangerous characters
    echo "$input" | sed 's/[^a-zA-Z0-9_\-@:.\/]//g'
}

# Function to backup current state
create_backup() {
    local backup_dir="$HOME/.commitsledger_backups"
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    # Create a backup of the current git repository state
    if [ -d .git ]; then
        tar -czf "$backup_file" .git 2>/dev/null
        log_message "Backup created at $backup_file"
    fi
}

# Function to display progress bar
display_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    
    printf "\rProgress: ["
    for ((i=0; i<completed; i++)); do
        printf "="
    done
    for ((i=completed; i<width; i++)); do
        printf " "
    done
    printf "] %d%% (%d/%d)" "$percentage" "$current" "$total"
}

# Function to cleanup temporary files
cleanup() {
    log_message "Performing cleanup operations"
    # Add any cleanup operations here
    # For example, remove temporary files if any were created
}

# Function to check git status
check_git_status() {
    if ! git status --porcelain 2>/dev/null | grep -q '^[^?].'; then
        log_message "No changes to commit in the repository"
    else
        log_message "Uncommitted changes detected in the repository"
    fi
}

# Parse command line arguments
parse_arguments "$@"

# Load configuration
load_config

# Set up trap for cleanup on exit
trap cleanup EXIT

# Validate git repository
validate_git_repo

# Check git status before operations
check_git_status

# Create backup before making changes
if [ "$DRY_RUN" = false ]; then
    create_backup
fi

# Get current branch
CURRENT_BRANCH=$(get_current_branch)

# Log start
log_message "Starting commitsledger synchronization for branch: $CURRENT_BRANCH"

# Display mode information
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN MODE: No actual pushes will be performed"
fi
echo "------------------------------------------"
echo "MODE:      Smart Auto-Detect"
echo "BRANCH:    $CURRENT_BRANCH"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN:   Enabled"
fi
echo "------------------------------------------"

# Loop through every remote you have (Origin, Gitlab, Heroku, etc.)
for REMOTE in $(git remote); do
    # Sanitize remote name
    REMOTE=$(sanitize_input "$REMOTE")
    
    # Validate remote name
    if ! validate_remote "$REMOTE"; then
        continue
    fi
    
    echo ""
    echo "CONNECTING TO REMOTE: [$REMOTE]..."
    
    # Validate connectivity to remote
    if ! validate_git_connectivity "$REMOTE"; then
        echo "Skipping remote '$REMOTE' due to connectivity issues."
        continue
    fi
    
    # Fetch latest data so we know the truth
    if ! git fetch "$REMOTE" > /dev/null 2>&1; then
        echo "Warning: Unable to fetch from remote '$REMOTE'. Skipping..."
        continue
    fi
    
    # Calculate the missing commits
    # Logic: "Show me commits that are on HEAD but NOT on remote/branch"
    # We use --reverse to get them Base -> Up
    MISSING_COMMITS=$(git log --reverse --pretty=format:"%H" "$REMOTE/$CURRENT_BRANCH"..HEAD 2>/dev/null)
    
    # Check if the command failed (usually means branch doesn't exist on remote yet)
    if [ $? -ne 0 ]; then
        echo "Warning: Branch '$CURRENT_BRANCH' not found on '$REMOTE'."
        echo "Assuming ALL commits need to be pushed..."
        MISSING_COMMITS=$(git log --reverse --pretty=format:"%H" 2>/dev/null)
    fi

    # Count them
    COUNT=$(get_commit_count "$MISSING_COMMITS")

    if [ "$COUNT" -eq "0" ]; then
        echo "Remote '$REMOTE' is already up to date."
        continue
    fi

    echo "Found $COUNT unpushed commits for '$REMOTE'."
    
    CURRENT=1
    
    # The Push Loop
    for commit_hash in $MISSING_COMMITS; do
        # Get commit message for display
        COMMIT_MESSAGE=$(get_commit_message "$commit_hash")
        
        if [ "$VERBOSE" = true ]; then
            display_progress "$CURRENT" "$COUNT"
        fi
        
        echo "[$CURRENT/$COUNT] Pushing ${commit_hash:0:7} to $REMOTE... ($COMMIT_MESSAGE)"
        
        if [ "$DRY_RUN" = false ]; then
            if ! git push "$REMOTE" "$commit_hash":refs/heads/"$CURRENT_BRANCH" 2>/dev/null; then
                handle_push_error "$REMOTE" "$commit_hash"
                break
            fi
        else
            log_message "DRY RUN: Would push ${commit_hash:0:7} to $REMOTE"
        fi
        
        ((CURRENT++))
        # Optional delay between pushes to be safe
        sleep "$PUSH_DELAY"
    done
    
    if [ "$DRY_RUN" = false ]; then
        echo ""
        echo "'$REMOTE' is now fully synchronized!"
    else
        echo "DRY RUN: Would have synchronized '$REMOTE' completely."
    fi
done

echo ""
if [ "$DRY_RUN" = false ]; then
    echo "ALL REMOTES UPDATED SUCCESSFULLY!"
    log_message "All remotes updated successfully"
else
    echo "DRY RUN COMPLETED - No changes made to remotes"
    log_message "Dry run completed successfully"
fi