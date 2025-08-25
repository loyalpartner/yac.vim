" yac_remote.vim - Simplified remote editing support
" Uses standard yac startup with environment variable passing

if exists('g:loaded_yac_remote')
  finish
endif
let g:loaded_yac_remote = 1

" Enhanced smart LSP start that detects SSH files
" Detects SSH files and enables remote mode automatically
function! yac_remote#enhanced_lsp_start() abort
  let l:filepath = expand('%:p')
  
  " Debug logging for mode detection
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Enhanced LSP start for: %s', l:filepath)
  endif
  
  " Check if this is an SSH file (scp:// or ssh:// protocol)  
  if l:filepath =~# '^s\(cp\|sh\)://'
    " SSH file detected - enable remote mode with path conversion
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: SSH file detected, enabling remote mode: %s', l:filepath)
    endif
    echo "SSH file detected: " . l:filepath
    call s:start_ssh_mode_with_path_conversion(l:filepath)
  else
    " Local file - use standard mode
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Local file detected, using standard mode: %s', l:filepath)
    endif
    call yac#start()
    call yac#open_file()
  endif
  
  return 1
endfunction

" Start SSH mode with path conversion for remote editing
function! s:start_ssh_mode_with_path_conversion(filepath) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Starting SSH mode with path conversion for: %s', a:filepath)
  endif
  
  " Parse SSH connection info from filepath
  " Format: scp://user@host//path/to/file or ssh://user@host/path/to/file
  " Note: scp:// uses // to indicate absolute path on remote machine
  let l:match = matchlist(a:filepath, '^s\(cp\|sh\)://\([^@]\+@[^/]\+\)\(//\?\(.*\)\)')
  
  if empty(l:match)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Failed to parse SSH path: %s', a:filepath)
    endif
    echoerr "Invalid SSH file format: " . a:filepath
    return
  endif
  
  let l:user_host = l:match[2]  " user@host (e.g., lee@127.0.0.1)
  let l:remote_path = l:match[4] " path without leading slashes (e.g., home/lee/.zshrc)
  
  " Ensure remote path starts with /
  if l:remote_path !~# '^/'
    let l:remote_path = '/' . l:remote_path
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Parsed connection - Host: %s, Path: %s', l:user_host, l:remote_path)
  endif
  
  echo "Parsed SSH: " . l:user_host . " -> " . l:remote_path
  
  " Convert SSH path to real path for LSP operations
  call s:convert_ssh_path_for_lsp(l:remote_path)
  
  " Set up remote environment
  call s:setup_remote_bridge(l:user_host, l:remote_path)
  
  " Start local bridge in forwarding mode
  call yac#start()
  
  " Open file with converted path
  call yac#open_file()
endfunction

" Convert SSH buffer path to real path for LSP operations
function! s:convert_ssh_path_for_lsp(real_path) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Converting SSH path for LSP: %s -> %s', expand('%:p'), a:real_path)
  endif
  
  " Store original SSH filepath for display
  let b:yac_original_ssh_path = expand('%:p')
  let b:yac_converted_path = a:real_path
  
  " Temporarily change buffer filename to real path for LSP
  " This ensures remote LSP server receives /home/lee/.zshrc instead of scp://...
  silent! execute 'file ' . fnameescape(a:real_path)
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Path conversion complete. Buffer filename now: %s', expand('%:p'))
  endif
  
  echo "Path converted for LSP: " . b:yac_original_ssh_path . " -> " . a:real_path
endfunction

" Restore original SSH path display (for future use)
function! s:restore_ssh_path_display() abort
  if exists('b:yac_original_ssh_path')
    silent! execute 'file ' . fnameescape(b:yac_original_ssh_path)
  endif
endfunction

" Set up remote lsp-bridge and SSH tunnel
function! s:setup_remote_bridge(user_host, remote_path) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Setting up remote bridge for %s (path: %s)', a:user_host, a:remote_path)
  endif
  
  " Generate unique socket paths for this SSH session
  let l:local_socket = '/tmp/yac-ssh-' . substitute(a:user_host, '@', '-', 'g') . '.sock'
  let l:remote_socket = '/tmp/yac-remote-' . substitute(a:user_host, '@', '-', 'g') . '.sock'
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Generated socket paths - Local: %s, Remote: %s', l:local_socket, l:remote_socket)
  endif
  
  " Set environment variables to enable SSH forwarding mode
  " YAC_SSH_HOST tells local lsp-bridge to use SSH forwarding
  " YAC_REMOTE_SOCKET tells the remote socket path
  let $YAC_SSH_HOST = a:user_host
  let $YAC_REMOTE_SOCKET = l:remote_socket
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Set environment variables - YAC_SSH_HOST: %s, YAC_REMOTE_SOCKET: %s', a:user_host, l:remote_socket)
  endif
  
  " Check if tunnel already exists
  if s:tunnel_exists(l:local_socket)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Tunnel already exists for %s, reusing', a:user_host)
    endif
    echo "SSH tunnel already active for " . a:user_host
    return
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: No existing tunnel found, setting up new tunnel for %s', a:user_host)
  endif
  
  echo "Setting up SSH tunnel for " . a:user_host . "..."
  
  " Deploy lsp-bridge binary to remote host
  if !s:deploy_remote_binary(a:user_host)
    echoerr "Failed to deploy lsp-bridge to remote host"
    return
  endif
  
  " Start remote lsp-bridge server
  if !s:start_remote_server(a:user_host, l:remote_socket)
    echoerr "Failed to start remote lsp-bridge server"
    return
  endif
  
  " Create SSH tunnel: local socket -> remote socket
  if !s:create_ssh_tunnel(a:user_host, l:local_socket, l:remote_socket)
    echoerr "Failed to create SSH tunnel"
    return
  endif
  
  " Store tunnel info for cleanup
  call s:register_tunnel(a:user_host, l:local_socket, l:remote_socket)
  
  echo "SSH tunnel established: " . a:user_host . " -> " . l:local_socket
endfunction

" Deploy lsp-bridge binary to remote host
function! s:deploy_remote_binary(user_host) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Starting binary deployment to %s', a:user_host)
  endif
  
  let l:local_binary = './target/release/lsp-bridge'
  let l:remote_path = 'lsp-bridge'  " Deploy to home directory without ~/
  
  " Check if remote binary already exists and is executable
  let l:remote_check_cmd = 'ssh ' . shellescape(a:user_host) . ' "test -x ' . shellescape(l:remote_path) . '"'
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Checking if remote binary exists: %s', l:remote_check_cmd)
  endif
  
  let l:result = system(l:remote_check_cmd)
  
  if v:shell_error == 0
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Remote binary already exists and is executable at %s:%s', a:user_host, l:remote_path)
    endif
    echo "Remote lsp-bridge binary already exists, skipping deployment"
    return 1
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Remote binary not found or not executable, proceeding with deployment')
  endif
  
  " Check if local binary exists
  if !filereadable(l:local_binary)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Local binary not found at %s, building...', l:local_binary)
    endif
    echo "Building lsp-bridge binary..."
    let l:result = system('cargo build --release')
    if v:shell_error != 0
      if get(g:, 'lsp_bridge_debug', 0)
        echom printf('YacDebug[SSH]: Build failed with error: %s', l:result)
      endif
      echoerr "Failed to build lsp-bridge: " . l:result
      return 0
    endif
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Build completed successfully')
    endif
  else
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Local binary exists at %s', l:local_binary)
    endif
  endif
  
  " Deploy binary via scp - use home directory directly
  echo "Deploying lsp-bridge to " . a:user_host . "..."
  let l:cmd = 'scp ' . shellescape(l:local_binary) . ' ' . shellescape(a:user_host) . ':' . shellescape(l:remote_path)
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Executing SCP command: %s', l:cmd)
  endif
  
  let l:result = system(l:cmd)
  
  if v:shell_error != 0
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: SCP failed with error: %s', l:result)
    endif
    echoerr "Failed to deploy binary: " . l:result
    return 0
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Binary deployed successfully, setting permissions')
  endif
  
  " Make binary executable
  let l:chmod_cmd = 'ssh ' . shellescape(a:user_host) . ' ' . shellescape('chmod +x ' . l:remote_path)
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Executing chmod command: %s', l:chmod_cmd)
  endif
  
  let l:result = system(l:chmod_cmd)
  
  if v:shell_error != 0
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Chmod failed with error: %s', l:result)
    endif
    echoerr "Failed to make binary executable: " . l:result
    return 0
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Binary deployment completed successfully for %s', a:user_host)
  endif
  
  return 1
endfunction

" Start remote lsp-bridge server
function! s:start_remote_server(user_host, remote_socket) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Starting remote server on %s (socket: %s)', a:user_host, a:remote_socket)
  endif
  
  " Kill any existing remote server for this socket
  call s:stop_remote_server(a:user_host, a:remote_socket)
  
  " Start remote lsp-bridge server in background 
  " YAC_UNIX_SOCKET tells remote lsp-bridge to act as server for LSP processing
  let l:remote_cmd = 'cd ~ && YAC_UNIX_SOCKET=' . shellescape(a:remote_socket) . ' ./lsp-bridge'
  let l:ssh_cmd = 'ssh -f ' . shellescape(a:user_host) . ' ' . shellescape(l:remote_cmd)
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Executing remote server command: %s', l:ssh_cmd)
  endif
  
  echo "Starting remote server: " . l:ssh_cmd
  let l:result = system(l:ssh_cmd)
  
  if v:shell_error != 0
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Remote server start failed: %s', l:result)
    endif
    echoerr "Failed to start remote server: " . l:result
    return 0
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Remote server started, waiting for socket creation')
  endif
  
  " Wait a moment for server to start
  sleep 500m
  
  " Verify server is running
  let l:check_cmd = 'ssh ' . shellescape(a:user_host) . ' "test -S ' . shellescape(a:remote_socket) . '"'
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Verifying remote socket exists: %s', l:check_cmd)
  endif
  
  let l:result = system(l:check_cmd)
  
  if v:shell_error != 0
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Socket verification failed: %s', l:result)
    endif
    echoerr "Remote server socket not found: " . a:remote_socket
    return 0
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Remote server started successfully on %s', a:user_host)
  endif
  
  return 1
endfunction

" Setup SSH connection info (no persistent tunnel needed)
function! s:create_ssh_tunnel(user_host, local_socket, remote_socket) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Setting up SSH connection for direct SSH forwarding: %s -> %s via %s', a:local_socket, a:remote_socket, a:user_host)
  endif
  
  " Clean up any existing local socket
  if filereadable(a:local_socket)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Removing existing local socket: %s', a:local_socket)
    endif
    call delete(a:local_socket)
  endif
  
  " Store SSH connection info for the bridge
  call s:store_ssh_connection(a:user_host, a:local_socket, a:remote_socket)
  
  " Verify remote server is ready by checking remote socket exists
  let l:check_cmd = 'ssh ' . shellescape(a:user_host) . ' "test -S ' . shellescape(a:remote_socket) . '"'
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Verifying remote server is ready: %s', l:check_cmd)
  endif
  
  let l:result = system(l:check_cmd)
  
  if v:shell_error != 0
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Remote socket verification failed: %s', l:result)
    endif
    echoerr "Remote server socket not ready: " . a:remote_socket
    return 0
  endif
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: SSH forwarder connection ready for %s', a:user_host)
  endif
  
  echo "SSH forwarder ready for " . a:user_host
  return 1
endfunction

" Store SSH connection information for the forwarder
function! s:store_ssh_connection(user_host, local_socket, remote_socket) abort
  if !exists('s:ssh_connections')
    let s:ssh_connections = {}
  endif
  let s:ssh_connections[a:user_host] = {
    \ 'local_socket': a:local_socket,
    \ 'remote_socket': a:remote_socket
  \ }
endfunction

" Check if SSH connection is already established  
function! s:tunnel_exists(local_socket) abort
  " In SSH forwarding mode, we check if we have an active SSH connection
  " rather than checking for local socket files
  if exists('s:ssh_connections')
    for [l:host, l:info] in items(s:ssh_connections)
      if l:info.local_socket ==# a:local_socket
        " Check if remote server is still running
        let l:check_cmd = 'ssh ' . shellescape(l:host) . ' "test -S ' . shellescape(l:info.remote_socket) . '"'
        return system(l:check_cmd) == 0 && v:shell_error == 0
      endif
    endfor
  endif
  return 0
endfunction

" Check if socket is active (can connect)
function! s:socket_is_active(socket_path) abort
  " Use netstat or ss to check if socket is in use
  let l:check_cmd = 'ss -x | grep ' . shellescape(a:socket_path)
  let l:result = system(l:check_cmd)
  return v:shell_error == 0
endfunction

" Stop remote lsp-bridge server
function! s:stop_remote_server(user_host, remote_socket) abort
  let l:kill_cmd = 'ssh ' . shellescape(a:user_host) . ' "pkill -f lsp-bridge || true"'
  call system(l:kill_cmd)
  
  " Clean up remote socket
  let l:cleanup_cmd = 'ssh ' . shellescape(a:user_host) . ' "rm -f ' . shellescape(a:remote_socket) . '"'
  call system(l:cleanup_cmd)
endfunction

" Tunnel registry for cleanup
let s:active_tunnels = {}

" Register active tunnel
function! s:register_tunnel(user_host, local_socket, remote_socket) abort
  let s:active_tunnels[a:user_host] = {
    \ 'local_socket': a:local_socket,
    \ 'remote_socket': a:remote_socket,
    \ 'pid': 0
    \ }
endfunction

" Clean up all active tunnels
function! yac_remote#cleanup_tunnels() abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Starting cleanup of %d active tunnels', len(s:active_tunnels))
  endif
  
  for [l:user_host, l:tunnel] in items(s:active_tunnels)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Cleaning up tunnel for %s (local: %s, remote: %s)', l:user_host, l:tunnel.local_socket, l:tunnel.remote_socket)
    endif
    
    echo "Cleaning up tunnel for " . l:user_host
    
    " Clean up SSH connection info (no persistent tunnels to kill)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Cleaning up SSH connection info for %s', l:user_host)
    endif
    
    " Remove local socket
    if filereadable(l:tunnel.local_socket)
      if get(g:, 'lsp_bridge_debug', 0)
        echom printf('YacDebug[SSH]: Removing local socket: %s', l:tunnel.local_socket)
      endif
      call delete(l:tunnel.local_socket)
    endif
    
    " Stop remote server
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Stopping remote server for %s', l:user_host)
    endif
    call s:stop_remote_server(l:user_host, l:tunnel.remote_socket)
  endfor
  
  let s:active_tunnels = {}
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Tunnel cleanup completed')
  endif
endfunction

" Reconnect tunnel if connection is lost
function! yac_remote#reconnect_tunnel(user_host) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Reconnecting tunnel for %s', a:user_host)
  endif
  
  if !has_key(s:active_tunnels, a:user_host)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: No tunnel registered for %s', a:user_host)
    endif
    echoerr "No tunnel registered for " . a:user_host
    return 0
  endif
  
  let l:tunnel = s:active_tunnels[a:user_host]
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Found existing tunnel config - Local: %s, Remote: %s', l:tunnel.local_socket, l:tunnel.remote_socket)
  endif
  
  echo "Reconnecting tunnel for " . a:user_host . "..."
  
  " Clean up existing tunnel
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Cleaning up existing tunnel for reconnection')
  endif
  call s:stop_remote_server(a:user_host, l:tunnel.remote_socket)
  
  " Re-establish tunnel
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SSH]: Re-establishing tunnel connection')
  endif
  
  if s:start_remote_server(a:user_host, l:tunnel.remote_socket) && 
     \ s:create_ssh_tunnel(a:user_host, l:tunnel.local_socket, l:tunnel.remote_socket)
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Tunnel reconnected successfully for %s', a:user_host)
    endif
    echo "Tunnel reconnected successfully"
    return 1
  else
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('YacDebug[SSH]: Tunnel reconnection failed for %s', a:user_host)
    endif
    echoerr "Failed to reconnect tunnel"
    return 0
  endif
endfunction