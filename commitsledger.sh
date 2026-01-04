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
    local remote_url=$(git remote get-url "$remote" 2>/dev/null)
    
    if [ -z "$remote_url" ]; then
        log_message "ERROR: Remote '$remote' does not exist."
        return 1
    fi
    
    if ! git ls-remote "$remote" > /dev/null 2>&1; then
        log_message "ERROR: Cannot connect to remote '$remote' ($remote_url). Check authentication and network."
        return 1
    fi
    return 0
}

# Function to get commit count
get_commit_count() {
    local commits="$1"
    # Use command substitution to get clean count
    local count=$(echo "$commits" | sed '/^$/d' | wc -l)
    echo $count
}

# Function to validate commit hashes
validate_commit_hashes() {
    local commits="$1"
    local valid_count=0
    
    for commit in $commits; do
        if git rev-parse --verify "$commit^{commit}" >/dev/null 2>&1; then
            ((valid_count++))
        else
            log_message "WARNING: Invalid commit hash detected: $commit"
        fi
    done
    
    log_message "Validated $valid_count commit hashes"
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

# Function to retry failed operations
retry_operation() {
    local operation="$1"
    local max_retries="${2:-3}"
    local retry_count=1
    
    while [ $retry_count -le $max_retries ]; do
        log_message "Attempt $retry_count of $max_retries for operation: $operation"
        
        if eval "$operation"; then
            log_message "Operation succeeded on attempt $retry_count"
            return 0
        else
            log_message "Operation failed on attempt $retry_count"
            if [ $retry_count -lt $max_retries ]; then
                sleep $((retry_count * 2))  # Exponential backoff
            fi
        fi
        ((retry_count++))
    done
    
    log_message "Operation failed after $max_retries attempts"
    return 1
}

# Function to sanitize input
sanitize_input() {
    local input="$1"
    # Remove potentially dangerous characters
    echo "$input" | sed 's/[^a-zA-Z0-9_@:.\/-]//g'
}

# Function to validate input length
validate_input_length() {
    local input="$1"
    local max_length="${2:-1000}"
    
    if [ ${#input} -gt $max_length ]; then
        log_message "ERROR: Input exceeds maximum length of $max_length characters"
        return 1
    fi
    
    return 0
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

# Function to create selective backup
create_selective_backup() {
    local backup_dir="$HOME/.commitsledger_selective_backups"
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/selective_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    # Backup only specific important files
    tar -czf "$backup_file" .git/HEAD .git/refs .git/config 2>/dev/null || true
    log_message "Selective backup created at $backup_file"
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

# Function to display detailed progress
display_detailed_progress() {
    local current="$1"
    local total="$2"
    local remote="$3"
    local operation="$4"
    
    local percentage=$((current * 100 / total))
    local timestamp=$(date '+%H:%M:%S')
    
    printf "\r[%s] %s: %d/%d (%d%%) - Remote: %s" "$timestamp" "$operation" "$current" "$total" "$percentage" "$remote"
}

# Function to cleanup temporary files
cleanup() {
    log_message "Performing cleanup operations"
    # Add any cleanup operations here
    # For example, remove temporary files if any were created
    
    # Clean up any temporary files created during operations
    local temp_files=$(find /tmp -name "commitsledger_*" -type f 2>/dev/null)
    if [ -n "$temp_files" ]; then
        log_message "Removing temporary files"
        rm -f $temp_files
    fi
}

# Function for enhanced cleanup
enhanced_cleanup() {
    log_message "Performing enhanced cleanup operations"
    
    # Cleanup temporary files
    find /tmp -name "commitsledger_*" -mindepth 1 -delete 2>/dev/null || true
    
    # Cleanup old backup files (older than 7 days)
    find "$HOME/.commitsledger_backups" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null || true
    
    # Cleanup old log files if they exist
    find "$HOME/.commitsledger_logs" -name "*.log" -mtime +30 -delete 2>/dev/null || true
}

# Function to check git status
check_git_status() {
    if ! git status --porcelain 2>/dev/null | grep -q '^[^?].'; then
        log_message "No changes to commit in the repository"
    else
        log_message "Uncommitted changes detected in the repository"
    fi
}

# Function to check git stash status
check_git_stash_status() {
    local stash_count=$(git stash list 2>/dev/null | wc -l)
    if [ "$stash_count" -gt 0 ]; then
        log_message "Found $stash_count stashed changes in the repository"
    else
        log_message "No stashed changes in the repository"
    fi
}

# Function to validate git installation
validate_git_installation() {
    if ! command -v git &> /dev/null; then
        log_message "ERROR: Git is not installed or not in PATH"
        exit 1
    fi
    
    # Check git version
    local git_version=$(git --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    log_message "Git version: $git_version"
    
    # Verify git configuration
    if ! git config --get user.name > /dev/null 2>&1; then
        log_message "WARNING: Git user.name is not configured"
    fi
    if ! git config --get user.email > /dev/null 2>&1; then
        log_message "WARNING: Git user.email is not configured"
    fi
}

# Function to validate permissions
validate_permissions() {
    if [ ! -r . ] || [ ! -w . ]; then
        log_message "ERROR: Insufficient permissions for current directory"
        exit 1
    fi
}

# Function to update configuration
update_config() {
    local key="$1"
    local value="$2"
    
    # Update the configuration variable
    case "$key" in
        "DRY_RUN")
            DRY_RUN="$value"
            ;;
        "LOG_FILE")
            LOG_FILE="$value"
            ;;
        "VERBOSE")
            VERBOSE="$value"
            ;;
        "PUSH_DELAY")
            PUSH_DELAY="$value"
            ;;
        *)
            log_message "Unknown configuration key: $key"
            ;;
    esac
}

# Function to validate configuration values
validate_config_values() {
    # Validate PUSH_DELAY is a positive number
    if ! [[ "$PUSH_DELAY" =~ ^[0-9]+\.?[0-9]*$ ]] || [ "$(echo "$PUSH_DELAY <= 0" | bc -l 2>/dev/null || echo "1")" -eq 1 ]; then
        log_message "WARNING: Invalid PUSH_DELAY value: $PUSH_DELAY, using default 0.5"
        PUSH_DELAY=0.5
    fi
    
    # Validate LOG_FILE path
    if [ -n "$LOG_FILE" ]; then
        local log_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$log_dir" ]; then
            log_message "WARNING: Log directory does not exist: $log_dir"
        fi
    fi
}

# Function to validate network connectivity
validate_network() {
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log_message "WARNING: Network connectivity issues detected"
        return 1
    fi
    return 0
}

# Function to validate specific remote connectivity
validate_remote_connectivity() {
    local remote="$1"
    local remote_url=$(git remote get-url "$remote" 2>/dev/null)
    
    if [ -z "$remote_url" ]; then
        log_message "ERROR: Remote '$remote' does not exist"
        return 1
    fi
    
    # Extract hostname from URL
    local hostname=$(echo "$remote_url" | sed -n 's|.*://\([^/]*\)/.*|\1|p' | sed 's/.*@//')
    if [ -z "$hostname" ]; then
        # Handle SSH URLs
        hostname=$(echo "$remote_url" | sed -n 's/.*@\(.*\):.*/\1/p')
    fi
    
    if [ -n "$hostname" ] && ! ping -c 1 "$hostname" &> /dev/null; then
        log_message "WARNING: Cannot reach remote host $hostname for '$remote'"
        return 1
    fi
    
    return 0
}

# Function to get git statistics
get_git_stats() {
    local stats_file="$HOME/.commitsledger_stats"
    
    # Count total commits in the repository
    local total_commits=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    log_message "Total commits in repository: $total_commits"
    
    # Count branches
    local branch_count=$(git branch -a | wc -l)
    log_message "Total branches: $branch_count"
    
    # Count remotes
    local remote_count=$(git remote | wc -l)
    log_message "Total remotes: $remote_count"
}

# Function to get detailed git statistics
get_detailed_git_stats() {
    # Count commits per branch
    for branch in $(git branch -r | grep -v '\->' | sed 's/origin\///'); do
        local branch_commits=$(git rev-list --count "origin/$branch" 2>/dev/null)
        log_message "Branch $branch: $branch_commits commits"
    done
    
    # Count tags
    local tag_count=$(git tag | wc -l)
    log_message "Total tags: $tag_count"
    
    # Count contributors
    local contributor_count=$(git shortlog -s -n | wc -l)
    log_message "Total contributors: $contributor_count"
    
    # Repository size
    local repo_size=$(du -sh . 2>/dev/null | cut -f1)
    log_message "Repository size: $repo_size"
}

# Function to create a summary report
create_summary_report() {
    local report_file="$HOME/.commitsledger_summary_$(date +%Y%m%d_%H%M%S).txt"
    
    echo "CommitsLedger Summary Report" > "$report_file"
    echo "Generated on: $(date)" >> "$report_file"
    echo "Branch: $CURRENT_BRANCH" >> "$report_file"
    echo "Operation mode: $(if [ "$DRY_RUN" = true ]; then echo "DRY RUN"; else echo "NORMAL"; fi)" >> "$report_file"
    echo "Log file: $LOG_FILE" >> "$report_file"
    echo "Verbose mode: $VERBOSE" >> "$report_file"
    
    log_message "Summary report created at $report_file"
}

# Function to create a detailed summary report
create_detailed_summary_report() {
    local report_file="$HOME/.commitsledger_detailed_summary_$(date +%Y%m%d_%H%M%S).txt"
    
    echo "CommitsLedger Detailed Summary Report" > "$report_file"
    echo "Generated on: $(date)" >> "$report_file"
    echo "========================================" >> "$report_file"
    echo "Branch: $CURRENT_BRANCH" >> "$report_file"
    echo "Operation mode: $(if [ "$DRY_RUN" = true ]; then echo "DRY RUN"; else echo "NORMAL"; fi)" >> "$report_file"
    echo "Log file: $LOG_FILE" >> "$report_file"
    echo "Verbose mode: $VERBOSE" >> "$report_file"
    echo "Push delay: $PUSH_DELAY seconds" >> "$report_file"
    echo "" >> "$report_file"
    
    # Add git statistics to the report
    echo "Git Statistics:" >> "$report_file"
    local total_commits=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    echo "  Total commits: $total_commits" >> "$report_file"
    local branch_count=$(git branch -a | wc -l)
    echo "  Total branches: $branch_count" >> "$report_file"
    local remote_count=$(git remote | wc -l)
    echo "  Total remotes: $remote_count" >> "$report_file"
    echo "" >> "$report_file"
    
    # Add remote sync details
    echo "Remote Synchronization Details:" >> "$report_file"
    for remote in $(git remote); do
        echo "  Remote: $remote" >> "$report_file"
        local remote_branches=$(git branch -r | grep "$remote/" | wc -l)
        echo "    Branches: $remote_branches" >> "$report_file"
    done
    
    log_message "Detailed summary report created at $report_file"
}

# Function to check available disk space
check_disk_space() {
    local required_space=1000000  # 1MB in bytes
    local available_space=$(df . | tail -1 | awk '{print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log_message "WARNING: Insufficient disk space. Available: ${available_space}KB, Required: ${required_space}KB"
        return 1
    fi
    
    log_message "Sufficient disk space available: ${available_space}KB"
    return 0
}

# Function to check disk space for git operations
check_git_disk_space() {
    local git_dir_size=0
    if [ -d .git ]; then
        git_dir_size=$(du -sb .git 2>/dev/null | cut -f1)
    fi
    
    # Estimate space needed for operations (10% of git directory size)
    local estimated_space=$((git_dir_size / 10))
    if [ $estimated_space -lt 1000000 ]; then  # Minimum 1MB
        estimated_space=1000000
    fi
    
    local available_space=$(df . | tail -1 | awk '{print $4 * 1024}')  # Convert to bytes
    
    if [ "$available_space" -lt "$estimated_space" ]; then
        log_message "WARNING: Insufficient disk space for git operations. Available: ${available_space} bytes, Estimated needed: ${estimated_space} bytes"
        return 1
    fi
    
    log_message "Sufficient space for git operations: ${available_space} bytes available, estimated ${estimated_space} bytes needed"
    return 0
}

# Function to check system resources
check_system_resources() {
    local memory_usage=$(free | grep Mem | awk '{printf "%.2f", $3/$2 * 100.0}')
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
    
    log_message "System resources - Memory usage: ${memory_usage}%"
    log_message "System resources - CPU usage: ${cpu_usage:-N/A}%"
    
    # Check if memory usage is too high
    # Use awk instead of bc for better portability
    if awk -v mem="$memory_usage" 'BEGIN { exit !(mem > 90) }'; then
        log_message "WARNING: High memory usage detected (${memory_usage}%)"
    fi
}

# Function to get detailed system resources
get_detailed_system_resources() {
    # Memory details
    local mem_total=$(free -h | grep Mem | awk '{print $2}')
    local mem_used=$(free -h | grep Mem | awk '{print $3}')
    local mem_available=$(free -h | grep Mem | awk '{print $7}')
    log_message "Memory - Total: $mem_total, Used: $mem_used, Available: $mem_available"
    
    # Disk usage
    local disk_usage=$(df -h . | tail -1 | awk '{print $5}' | sed 's/%//')
    local disk_total=$(df -h . | tail -1 | awk '{print $2}')
    local disk_used=$(df -h . | tail -1 | awk '{print $3}')
    log_message "Disk - Usage: ${disk_usage}%, Total: $disk_total, Used: $disk_used"
    
    # Check if system resources are adequate
    if [ "$disk_usage" -gt 90 ]; then
        log_message "WARNING: High disk usage detected (${disk_usage}%)"
    fi
}

# Function to validate git authentication
validate_git_auth() {
    for remote in $(git remote); do
        if ! git ls-remote "$remote" HEAD &>/dev/null; then
            log_message "WARNING: Authentication failed for remote '$remote'"
            return 1
        fi
    done
    return 0
}

# Function to validate git authentication with detailed feedback
validate_git_auth_detailed() {
    local auth_success=0
    local auth_failed=0
    
    for remote in $(git remote); do
        local remote_url=$(git remote get-url "$remote" 2>/dev/null)
        if ! git ls-remote "$remote" HEAD &>/dev/null; then
            log_message "Authentication failed for remote '$remote' ($remote_url)"
            ((auth_failed++))
        else
            log_message "Authentication successful for remote '$remote'"
            ((auth_success++))
        fi
    done
    
    log_message "Authentication summary: $auth_success successful, $auth_failed failed"
    
    if [ $auth_failed -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Function to set git configuration
set_git_config() {
    # Set git configuration options for the operation
    git config push.default simple
    git config core.preloadindex true
    git config core.fscache true
    log_message "Git configuration set for optimal performance"
}

# Function to validate git credentials
validate_git_credentials() {
    for remote in $(git remote); do
        local remote_url=$(git remote get-url "$remote" 2>/dev/null)
        if [[ "$remote_url" =~ ^https://.*@.* ]]; then
            log_message "WARNING: Credentials detected in remote URL for '$remote'. Consider using credential manager."
        fi
    done
}

# Function to validate git hooks
validate_git_hooks() {
    local hooks_dir=".git/hooks"
    if [ -d "$hooks_dir" ]; then
        local hook_count=$(find "$hooks_dir" -type f -executable | wc -l)
        log_message "Found $hook_count git hooks in repository"
        
        # Check for pre-push hooks which might affect our operations
        if [ -f "$hooks_dir/pre-push" ]; then
            log_message "WARNING: pre-push hook detected, this may affect push operations"
        fi
    fi
}

# Function to create a version info function
print_version() {
    echo "CommitsLedger v1.0.0"
    echo "Enhanced Git Synchronization Utility"
    echo "Build date: $(date)"
}

# Parse command line arguments
parse_arguments "$@"

# Load configuration
load_config

# Set up trap for cleanup on exit
trap cleanup EXIT

# Validate git installation
validate_git_installation

# Validate permissions
validate_permissions

# Check system resources
check_system_resources

# Check disk space
check_disk_space

# Validate network connectivity
validate_network

# Validate git authentication
validate_git_auth

# Validate git credentials
validate_git_credentials

# Validate git hooks
validate_git_hooks

# Set git configuration
set_git_config

# Validate git repository
validate_git_repo

# Get git statistics
get_git_stats

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

# Create summary report
create_summary_report