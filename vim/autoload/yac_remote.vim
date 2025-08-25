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
  
  " Check if this is an SSH file (scp:// or ssh:// protocol)
  if l:filepath =~# '^s\(cp\|sh\)://'
    " SSH file detected - enable remote mode
    echo "SSH file detected: " . l:filepath
    call s:start_ssh_mode(l:filepath)
  else
    " Local file - use standard mode
    call yac#start()
  endif
  
  call yac#open_file()
  return 1
endfunction

" Start SSH mode for remote editing
function! s:start_ssh_mode(filepath) abort
  " Parse SSH connection info from filepath
  " Format: scp://user@host//path/to/file or ssh://user@host/path/to/file
  let l:match = matchlist(a:filepath, '^s\(cp\|sh\)://\([^@]\+@[^/]\+\)\(/.*\)\?')
  
  if empty(l:match)
    echoerr "Invalid SSH file format: " . a:filepath
    return
  endif
  
  let l:user_host = l:match[2]  " user@host
  let l:remote_path = l:match[3] " /path/to/file
  
  " Set up remote environment
  call s:setup_remote_bridge(l:user_host, l:remote_path)
  
  " Start local bridge in forwarding mode
  call yac#start()
endfunction

" Set up remote lsp-bridge and SSH tunnel
function! s:setup_remote_bridge(user_host, remote_path) abort
  " Generate unique socket paths for this SSH session
  let l:local_socket = '/tmp/yac-ssh-' . substitute(a:user_host, '@', '-', 'g') . '.sock'
  let l:remote_socket = '/tmp/yac-remote-' . substitute(a:user_host, '@', '-', 'g') . '.sock'
  
  " Set environment variable to enable Unix socket mode
  " This tells local lsp-bridge to use Unix socket instead of stdio
  let $YAC_UNIX_SOCKET = l:local_socket
  
  " Check if tunnel already exists
  if s:tunnel_exists(l:local_socket)
    echo "SSH tunnel already active for " . a:user_host
    return
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
  let l:local_binary = './target/release/lsp-bridge'
  let l:remote_path = '~/lsp-bridge'
  
  " Check if local binary exists
  if !filereadable(l:local_binary)
    echo "Building lsp-bridge binary..."
    let l:result = system('cargo build --release')
    if v:shell_error != 0
      echoerr "Failed to build lsp-bridge: " . l:result
      return 0
    endif
  endif
  
  " Deploy binary via scp
  echo "Deploying lsp-bridge to " . a:user_host . "..."
  let l:cmd = 'scp ' . shellescape(l:local_binary) . ' ' . shellescape(a:user_host . ':' . l:remote_path)
  let l:result = system(l:cmd)
  
  if v:shell_error != 0
    echoerr "Failed to deploy binary: " . l:result
    return 0
  endif
  
  " Make binary executable
  let l:chmod_cmd = 'ssh ' . shellescape(a:user_host) . ' "chmod +x ' . l:remote_path . '"'
  let l:result = system(l:chmod_cmd)
  
  if v:shell_error != 0
    echoerr "Failed to make binary executable: " . l:result
    return 0
  endif
  
  return 1
endfunction

" Start remote lsp-bridge server
function! s:start_remote_server(user_host, remote_socket) abort
  " Kill any existing remote server for this socket
  call s:stop_remote_server(a:user_host, a:remote_socket)
  
  " Start remote lsp-bridge in background
  let l:remote_cmd = 'cd ~ && YAC_UNIX_SOCKET=' . shellescape(a:remote_socket) . ' ./lsp-bridge'
  let l:ssh_cmd = 'ssh -f ' . shellescape(a:user_host) . ' ' . shellescape(l:remote_cmd)
  
  echo "Starting remote server: " . l:ssh_cmd
  let l:result = system(l:ssh_cmd)
  
  if v:shell_error != 0
    echoerr "Failed to start remote server: " . l:result
    return 0
  endif
  
  " Wait a moment for server to start
  sleep 500m
  
  " Verify server is running
  let l:check_cmd = 'ssh ' . shellescape(a:user_host) . ' "test -S ' . shellescape(a:remote_socket) . '"'
  let l:result = system(l:check_cmd)
  
  if v:shell_error != 0
    echoerr "Remote server socket not found: " . a:remote_socket
    return 0
  endif
  
  return 1
endfunction

" Create SSH tunnel between local and remote sockets
function! s:create_ssh_tunnel(user_host, local_socket, remote_socket) abort
  " Remove existing local socket if it exists
  if filereadable(a:local_socket)
    call delete(a:local_socket)
  endif
  
  " Create SSH tunnel: local socket forwards to remote socket
  let l:tunnel_cmd = 'ssh -f -N -L ' . shellescape(a:local_socket) . ':' . shellescape(a:remote_socket) . ' ' . shellescape(a:user_host)
  
  echo "Creating tunnel: " . l:tunnel_cmd
  let l:result = system(l:tunnel_cmd)
  
  if v:shell_error != 0
    echoerr "Failed to create SSH tunnel: " . l:result
    return 0
  endif
  
  " Wait for tunnel to establish
  sleep 200m
  
  " Verify local socket exists
  let l:wait_count = 0
  while !filereadable(a:local_socket) && l:wait_count < 10
    sleep 100m
    let l:wait_count += 1
  endwhile
  
  if !filereadable(a:local_socket)
    echoerr "Tunnel socket not created: " . a:local_socket
    return 0
  endif
  
  return 1
endfunction

" Check if tunnel already exists
function! s:tunnel_exists(local_socket) abort
  return filereadable(a:local_socket) && s:socket_is_active(a:local_socket)
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
  for [l:user_host, l:tunnel] in items(s:active_tunnels)
    echo "Cleaning up tunnel for " . l:user_host
    
    " Kill SSH tunnel process
    let l:kill_ssh = 'pkill -f "ssh.*' . l:tunnel.local_socket . '"'
    call system(l:kill_ssh)
    
    " Remove local socket
    if filereadable(l:tunnel.local_socket)
      call delete(l:tunnel.local_socket)
    endif
    
    " Stop remote server
    call s:stop_remote_server(l:user_host, l:tunnel.remote_socket)
  endfor
  
  let s:active_tunnels = {}
endfunction

" Reconnect tunnel if connection is lost
function! yac_remote#reconnect_tunnel(user_host) abort
  if !has_key(s:active_tunnels, a:user_host)
    echoerr "No tunnel registered for " . a:user_host
    return 0
  endif
  
  let l:tunnel = s:active_tunnels[a:user_host]
  
  echo "Reconnecting tunnel for " . a:user_host . "..."
  
  " Clean up existing tunnel
  call s:stop_remote_server(a:user_host, l:tunnel.remote_socket)
  
  " Re-establish tunnel
  if s:start_remote_server(a:user_host, l:tunnel.remote_socket) && 
     \ s:create_ssh_tunnel(a:user_host, l:tunnel.local_socket, l:tunnel.remote_socket)
    echo "Tunnel reconnected successfully"
    return 1
  else
    echoerr "Failed to reconnect tunnel"
    return 0
  endif
endfunction