# CommitsLedger

A professional bash utility script that automatically detects git branches and remotes, calculates missing commits, and pushes them incrementally to keep all remotes synchronized.

## Description

CommitsLedger is a smart git synchronization utility that:
- Detects the current git branch
- Identifies all configured remotes (origin, gitlab, heroku, etc.)
- Calculates missing commits for each remote automatically
- Pushes commits incrementally to maintain synchronization across all remotes
- Supports dry-run mode, logging, and configurable options

## Features

- Automatic branch detection
- Multi-remote support
- Incremental commit pushing
- Real-time synchronization status
- Error handling for non-existent remote branches
- Dry-run mode for previewing operations
- Configurable settings via config file
- Logging capabilities
- Command-line options support
- Enhanced progress indicators
- Authentication error handling

## Installation

1. Make the script executable:
   ```bash
   chmod +x commitsledger.sh
   ```

2. (Optional) Copy to a location in your PATH:
   ```bash
   sudo cp commitsledger.sh /usr/local/bin/commitsledger
   ```

## Usage

Basic usage:
```bash
./commitsledger.sh
```

With options:
```bash
# Dry run - show what would be pushed without actually pushing
./commitsledger.sh --dry-run

# Verbose output with logging
./commitsledger.sh --verbose --log /tmp/commitsledger.log

# Use custom configuration file
./commitsledger.sh --config /path/to/config.conf

# Show help
./commitsledger.sh --help
```

## Configuration

Create a configuration file at `~/.commitsledger.conf` or specify a custom location with `--config`:

```bash
# Push delay in seconds (default: 0.5)
PUSH_DELAY=0.5

# Default log file location (empty means no logging by default)
LOG_FILE=""

# Default verbose mode (true/false)
VERBOSE=false

# Additional git options for push operations
# GIT_PUSH_OPTIONS="--no-verify"  # Uncomment to bypass git hooks during push
```

## Requirements

- Git (version 2.0 or higher recommended)
- Bash shell (version 4.0 or higher)
- Appropriate permissions for git operations

## How It Works

The script uses git log commands with specific formatting to identify commits that exist locally but not on remote repositories. It then pushes these commits one by one to ensure proper synchronization across all configured remotes. The process includes:

1. Detection of the current branch
2. Loop through all configured remotes
3. Fetch latest data from each remote
4. Calculate missing commits using git log comparison
5. Push commits incrementally with error handling
6. Provide detailed progress information

## Security

- The script validates git repository status before operations
- Includes connectivity checks before attempting to push
- Provides dry-run mode to preview operations
- Supports bypassing git hooks if needed via configuration