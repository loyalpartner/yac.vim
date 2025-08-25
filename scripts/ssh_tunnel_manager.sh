#!/bin/bash
# SSH Unix Socket Tunnel Manager for yac.vim remote editing
# Provides robust SSH tunnel management for Unix domain sockets

set -euo pipefail

# Configuration
SCRIPT_NAME="ssh_tunnel_manager"
PID_DIR="/tmp/yac_tunnels"
LOG_FILE="/tmp/yac_tunnel.log"

# Ensure PID directory exists
mkdir -p "$PID_DIR"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Help message
show_help() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  establish <user@host> <local_socket> <remote_socket>
    Establish SSH Unix socket tunnel
    
  cleanup <local_socket>
    Clean up tunnel and remove socket files
    
  status <local_socket>
    Check if tunnel is active
    
  list
    List all active tunnels

Examples:
  $0 establish dev@server /tmp/yac-local-123 /tmp/yac-remote-123
  $0 cleanup /tmp/yac-local-123
  $0 status /tmp/yac-local-123

EOF
}

# Establish SSH Unix socket tunnel
establish_tunnel() {
    local user_host="$1"
    local local_socket="$2"
    local remote_socket="$3"
    
    local socket_hash=$(echo "$local_socket" | sha256sum | cut -d' ' -f1 | head -c8)
    local pid_file="$PID_DIR/tunnel_${socket_hash}.pid"
    local log_file="$PID_DIR/tunnel_${socket_hash}.log"
    
    # Check if tunnel already exists
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        log "Tunnel already exists for $local_socket"
        return 0
    fi
    
    # Clean up any stale socket files
    rm -f "$local_socket"
    
    log "Establishing SSH tunnel: $local_socket -> $user_host:$remote_socket"
    
    # Build SSH command with Unix socket forwarding
    # -L local_socket:remote_socket forwards Unix socket through SSH
    # -N prevents remote command execution
    # -f runs in background
    # -o ServerAliveInterval=60 keeps connection alive
    # -o ServerAliveCountMax=3 allows 3 missed keepalives
    ssh -L "$local_socket:$remote_socket" \
        -N -f \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        "$user_host" \
        > "$log_file" 2>&1 &
    
    local ssh_pid=$!
    
    # Wait briefly and check if SSH started successfully
    sleep 1
    if ! kill -0 "$ssh_pid" 2>/dev/null; then
        log "ERROR: Failed to establish SSH tunnel"
        cat "$log_file"
        return 1
    fi
    
    # Save PID for cleanup
    echo "$ssh_pid" > "$pid_file"
    log "SSH tunnel established successfully (PID: $ssh_pid)"
    log "Local socket: $local_socket"
    
    return 0
}

# Clean up tunnel
cleanup_tunnel() {
    local local_socket="$1"
    
    local socket_hash=$(echo "$local_socket" | sha256sum | cut -d' ' -f1 | head -c8)
    local pid_file="$PID_DIR/tunnel_${socket_hash}.pid"
    local log_file="$PID_DIR/tunnel_${socket_hash}.log"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        log "Terminating SSH tunnel (PID: $pid)"
        
        if kill "$pid" 2>/dev/null; then
            # Wait for process to terminate
            for i in {1..10}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done
            
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log "Force killing tunnel process"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        
        rm -f "$pid_file"
        log "Tunnel PID file removed"
    fi
    
    # Clean up socket files
    if [[ -S "$local_socket" ]]; then
        rm -f "$local_socket"
        log "Local socket file removed: $local_socket"
    fi
    
    # Clean up log file
    rm -f "$log_file"
    
    log "Tunnel cleanup completed for $local_socket"
}

# Check tunnel status
tunnel_status() {
    local local_socket="$1"
    
    local socket_hash=$(echo "$local_socket" | sha256sum | cut -d' ' -f1 | head -c8)
    local pid_file="$PID_DIR/tunnel_${socket_hash}.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "ACTIVE (PID: $pid)"
            return 0
        else
            echo "STALE (PID file exists but process dead)"
            return 1
        fi
    else
        echo "INACTIVE"
        return 1
    fi
}

# List all active tunnels
list_tunnels() {
    echo "Active SSH tunnels:"
    echo "==================="
    
    local count=0
    for pid_file in "$PID_DIR"/tunnel_*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                local socket_hash=$(basename "$pid_file" .pid | sed 's/tunnel_//')
                echo "PID: $pid, Hash: $socket_hash"
                count=$((count + 1))
            fi
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        echo "No active tunnels found."
    fi
}

# Main command dispatcher
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        establish)
            if [[ $# -ne 3 ]]; then
                echo "ERROR: establish requires 3 arguments"
                show_help
                exit 1
            fi
            establish_tunnel "$@"
            ;;
        cleanup)
            if [[ $# -ne 1 ]]; then
                echo "ERROR: cleanup requires 1 argument"
                show_help
                exit 1
            fi
            cleanup_tunnel "$@"
            ;;
        status)
            if [[ $# -ne 1 ]]; then
                echo "ERROR: status requires 1 argument"
                show_help
                exit 1
            fi
            tunnel_status "$@"
            ;;
        list)
            list_tunnels
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "ERROR: Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"