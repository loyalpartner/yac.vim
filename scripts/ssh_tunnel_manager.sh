#!/bin/bash
# SSH tunnel management for yac.vim remote editing
# Linus-style: Simple, focused script that does one thing well

set -euo pipefail

readonly TUNNEL_PID_DIR="/tmp/yac_tunnels"

# Ensure tunnel PID directory exists
mkdir -p "$TUNNEL_PID_DIR"

establish_tunnel() {
    local user_host="$1"
    local port="$2"
    
    # Check if tunnel already exists
    if pgrep -f "ssh -L $port:localhost:$port.*$user_host" > /dev/null; then
        echo "Tunnel already exists for $user_host:$port"
        return 0
    fi
    
    echo "Establishing SSH tunnel: localhost:$port -> $user_host:$port"
    
    # Establish new tunnel (-f runs in background, -N no remote commands)
    ssh -L "$port:localhost:$port" -N -f "$user_host" || {
        echo "Failed to establish SSH tunnel" >&2
        return 1
    }
    
    # Record PID for cleanup
    pgrep -f "ssh -L $port:localhost:$port.*$user_host" > "$TUNNEL_PID_DIR/tunnel_${port}.pid"
    echo "SSH tunnel established successfully"
}

cleanup_tunnel() {
    local port="$1"
    local pid_file="$TUNNEL_PID_DIR/tunnel_${port}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill "$pid" 2>/dev/null; then
            echo "Cleaned up tunnel on port $port (PID: $pid)"
        else
            echo "Tunnel process $pid not found or already terminated"
        fi
        rm -f "$pid_file"
    else
        echo "No tunnel record found for port $port"
    fi
}

list_tunnels() {
    echo "Active SSH tunnels:"
    for pid_file in "$TUNNEL_PID_DIR"/tunnel_*.pid; do
        if [ -f "$pid_file" ]; then
            local port
            port=$(basename "$pid_file" | sed 's/tunnel_\(.*\)\.pid/\1/')
            local pid
            pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Port $port (PID: $pid) - Active"
            else
                echo "  Port $port (PID: $pid) - Stale"
                rm -f "$pid_file"
            fi
        fi
    done
}

cleanup_all_tunnels() {
    for pid_file in "$TUNNEL_PID_DIR"/tunnel_*.pid; do
        if [ -f "$pid_file" ]; then
            local port
            port=$(basename "$pid_file" | sed 's/tunnel_\(.*\)\.pid/\1/')
            cleanup_tunnel "$port"
        fi
    done
}

check_tunnel() {
    local port="$1"
    local pid_file="$TUNNEL_PID_DIR/tunnel_${port}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "active"
        else
            rm -f "$pid_file"
            echo "inactive"
        fi
    else
        echo "inactive"
    fi
}

usage() {
    echo "Usage: $0 {establish_tunnel|cleanup_tunnel|list_tunnels|cleanup_all|check_tunnel} [args...]"
    echo "Commands:"
    echo "  establish_tunnel USER@HOST PORT - Establish SSH tunnel"
    echo "  cleanup_tunnel PORT            - Clean up tunnel on specific port"
    echo "  check_tunnel PORT              - Check if tunnel is active"
    echo "  list_tunnels                   - List all active tunnels"
    echo "  cleanup_all                    - Clean up all tunnels"
}

case "${1:-}" in
    "establish_tunnel")
        if [ $# -ne 3 ]; then
            echo "Usage: $0 establish_tunnel USER@HOST PORT" >&2
            exit 1
        fi
        establish_tunnel "$2" "$3"
        ;;
    "cleanup_tunnel")
        if [ $# -ne 2 ]; then
            echo "Usage: $0 cleanup_tunnel PORT" >&2
            exit 1
        fi
        cleanup_tunnel "$2"
        ;;
    "check_tunnel")
        if [ $# -ne 2 ]; then
            echo "Usage: $0 check_tunnel PORT" >&2
            exit 1
        fi
        check_tunnel "$2"
        ;;
    "list_tunnels")
        list_tunnels
        ;;
    "cleanup_all")
        cleanup_all_tunnels
        ;;
    *)
        usage
        exit 1
        ;;
esac