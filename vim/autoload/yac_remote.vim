" yac_remote.vim - Remote editing support via SSH Unix socket tunneling
" Implements transparent remote LSP functionality through SSH tunnels

if exists('g:loaded_yac_remote')
  finish
endif
let g:loaded_yac_remote = 1

" ================================================================
" SSH File Detection and Parsing
" ================================================================

" Check if a file path is an SSH file
function! s:is_ssh_file(filepath) abort
  return match(a:filepath, '^s\(cp\|ftp\)://') >= 0
endfunction

" Parse SSH file path into components
" Input: scp://user@host//path/to/file.rs
" Output: {'user': 'user', 'host': 'host', 'path': '/path/to/file.rs'}
function! s:parse_ssh_path(ssh_filepath) abort
  let l:pattern = '^s\(cp\|ftp\)://\([^@]\+\)@\([^/]\+\)//\(.*\)$'
  let l:matches = matchlist(a:ssh_filepath, l:pattern)
  
  if empty(l:matches)
    throw 'Invalid SSH file path format: ' . a:ssh_filepath
  endif
  
  return {
    \ 'protocol': l:matches[1] == 'cp' ? 'scp' : 'sftp',
    \ 'user': l:matches[2],
    \ 'host': l:matches[3], 
    \ 'path': '/' . l:matches[4],
    \ 'connection': l:matches[2] . '@' . l:matches[3]
  \ }
endfunction

" ================================================================
" SSH Tunnel Management
" ================================================================

" Generate unique socket paths for this Vim instance
function! s:generate_socket_paths() abort
  let l:vim_pid = getpid()
  let l:timestamp = localtime()
  let l:local_socket = printf('/tmp/yac-local-%d-%d', l:vim_pid, l:timestamp)
  let l:remote_socket = printf('/tmp/yac-remote-%d-%d', l:vim_pid, l:timestamp)
  
  return {
    \ 'local': l:local_socket,
    \ 'remote': l:remote_socket
  \ }
endfunction

" Check if SSH tunnel exists for given connection
function! s:tunnel_exists(connection_key) abort
  let l:socket_paths = get(g:yac_remote_tunnels, a:connection_key, {})
  if empty(l:socket_paths)
    return 0
  endif
  
  " Check if tunnel script reports it as active
  let l:cmd = printf('%s/scripts/ssh_tunnel_manager.sh status %s', 
    \ g:yac_bridge_base_dir, l:socket_paths.local)
  let l:status = system(l:cmd)
  
  return match(l:status, 'ACTIVE') >= 0
endfunction

" Establish SSH tunnel for remote connection
function! s:establish_ssh_tunnel(ssh_info) abort
  let l:connection_key = a:ssh_info.connection
  
  " Check if tunnel already exists
  if s:tunnel_exists(l:connection_key)
    echomsg 'SSH tunnel already active for ' . l:connection_key
    return g:yac_remote_tunnels[l:connection_key]
  endif
  
  " Generate new socket paths
  let l:socket_paths = s:generate_socket_paths()
  
  " Establish tunnel using the tunnel manager script
  let l:cmd = printf('%s/scripts/ssh_tunnel_manager.sh establish %s %s %s',
    \ g:yac_bridge_base_dir,
    \ a:ssh_info.connection,
    \ l:socket_paths.local,
    \ l:socket_paths.remote)
  
  echomsg 'Establishing SSH tunnel for ' . a:ssh_info.connection . '...'
  let l:result = system(l:cmd)
  
  if v:shell_error != 0
    echoerr 'Failed to establish SSH tunnel: ' . l:result
    return {}
  endif
  
  " Store tunnel information
  if !exists('g:yac_remote_tunnels')
    let g:yac_remote_tunnels = {}
  endif
  let g:yac_remote_tunnels[l:connection_key] = l:socket_paths
  
  echomsg 'SSH tunnel established: ' . l:socket_paths.local
  return l:socket_paths
endfunction

" ================================================================
" Remote LSP Bridge Management
" ================================================================

" Check if remote lsp-bridge binary exists
function! s:check_remote_lsp_bridge(ssh_info) abort
  let l:cmd = printf('ssh %s "test -f ~/.local/bin/lsp-bridge && echo exists"',
    \ a:ssh_info.connection)
  let l:result = system(l:cmd)
  
  return match(l:result, 'exists') >= 0
endfunction

" Upload lsp-bridge binary to remote host
function! s:upload_lsp_bridge(ssh_info) abort
  let l:local_binary = g:yac_bridge_base_dir . '/target/release/lsp-bridge'
  
  " Check if local binary exists
  if !filereadable(l:local_binary)
    echoerr 'Local lsp-bridge binary not found. Run: cargo build --release'
    return 0
  endif
  
  " Create remote directory
  let l:mkdir_cmd = printf('ssh %s "mkdir -p ~/.local/bin"', a:ssh_info.connection)
  call system(l:mkdir_cmd)
  
  " Upload binary
  let l:scp_cmd = printf('scp %s %s:~/.local/bin/', l:local_binary, a:ssh_info.connection)
  echomsg 'Uploading lsp-bridge to ' . a:ssh_info.connection . '...'
  let l:result = system(l:scp_cmd)
  
  if v:shell_error != 0
    echoerr 'Failed to upload lsp-bridge: ' . l:result
    return 0
  endif
  
  " Set executable permission
  let l:chmod_cmd = printf('ssh %s "chmod +x ~/.local/bin/lsp-bridge"', a:ssh_info.connection)
  call system(l:chmod_cmd)
  
  echomsg 'lsp-bridge uploaded successfully'
  return 1
endfunction

" Start remote lsp-bridge in server mode
function! s:start_remote_lsp_bridge(ssh_info, socket_paths) abort
  " Kill any existing remote bridge processes
  let l:kill_cmd = printf('ssh %s "pkill -f lsp-bridge || true"', a:ssh_info.connection)
  call system(l:kill_cmd)
  
  " Start remote bridge in server mode with SSH info for path conversion
  let l:start_cmd = printf('ssh %s "cd ~ && YAC_UNIX_SOCKET=%s YAC_SERVER_MODE=1 YAC_SSH_USER=%s YAC_SSH_HOST=%s ~/.local/bin/lsp-bridge > /tmp/lsp-bridge-remote.log 2>&1 &"',
    \ a:ssh_info.connection,
    \ a:socket_paths.remote,
    \ a:ssh_info.user,
    \ a:ssh_info.host)
  
  echomsg 'Starting remote lsp-bridge server...'
  let l:result = system(l:start_cmd)
  
  " Give it a moment to start
  sleep 1000m
  
  return v:shell_error == 0
endfunction

" ================================================================
" Main Remote Bridge Startup Function
" ================================================================

" Smart LSP startup for remote files
function! yac_remote#smart_lsp_start(ssh_filepath) abort
  try
    " Parse SSH file path
    let l:ssh_info = s:parse_ssh_path(a:ssh_filepath)
    echomsg 'Detected SSH file: ' . l:ssh_info.connection . ':' . l:ssh_info.path
    
    " Establish SSH tunnel
    let l:socket_paths = s:establish_ssh_tunnel(l:ssh_info)
    if empty(l:socket_paths)
      return 0
    endif
    
    " Check and upload remote lsp-bridge if needed
    if !s:check_remote_lsp_bridge(l:ssh_info)
      echomsg 'Remote lsp-bridge not found, uploading...'
      if !s:upload_lsp_bridge(l:ssh_info)
        return 0
      endif
    else
      echomsg 'Remote lsp-bridge found'
    endif
    
    " Start remote lsp-bridge server
    if !s:start_remote_lsp_bridge(l:ssh_info, l:socket_paths)
      echoerr 'Failed to start remote lsp-bridge server'
      return 0
    endif
    
    " Configure local bridge to connect to tunnel
    call s:configure_local_bridge_client(l:socket_paths)
    
    echomsg 'Remote LSP bridge ready for ' . l:ssh_info.connection
    return 1
    
  catch
    echoerr 'Remote LSP setup failed: ' . v:exception
    return 0
  endtry
endfunction

" Configure local bridge as client
function! s:configure_local_bridge_client(socket_paths) abort
  " Stop any existing local bridge
  if exists('g:yac_job') && !empty(g:yac_job)
    call job_stop(g:yac_job)
  endif
  
  " Start local bridge in client mode
  let l:env = {
    \ 'YAC_UNIX_SOCKET': a:socket_paths.local
  \ }
  
  let l:cmd = g:yac_bridge_command
  let g:yac_job = job_start(l:cmd, {
    \ 'mode': 'json',
    \ 'callback': 'yac#on_data',
    \ 'exit_cb': 'yac#on_exit',
    \ 'env': l:env
  \ })
  
  " Wait for connection
  sleep 500m
  
  let g:yac_channel = job_getchannel(g:yac_job)
  echomsg 'Local bridge connected via Unix socket'
endfunction

" ================================================================
" Enhanced File Detection Integration
" ================================================================

" Enhanced smart LSP start that detects SSH files
function! yac_remote#enhanced_lsp_start() abort
  let l:filepath = expand('%:p')
  
  if s:is_ssh_file(l:filepath)
    " SSH file detected - use remote bridge
    return yac_remote#smart_lsp_start(l:filepath)
  else
    " Local file - use standard bridge
    call yac#start()
    call yac#open_file()
    return 1
  endif
endfunction

" ================================================================
" Cleanup Functions
" ================================================================

" Clean up all SSH tunnels for this Vim instance
function! yac_remote#cleanup_tunnels() abort
  if !exists('g:yac_remote_tunnels')
    return
  endif
  
  for [l:connection, l:socket_paths] in items(g:yac_remote_tunnels)
    let l:cmd = printf('%s/scripts/ssh_tunnel_manager.sh cleanup %s',
      \ g:yac_bridge_base_dir, l:socket_paths.local)
    call system(l:cmd)
    echomsg 'Cleaned up tunnel for ' . l:connection
  endfor
  
  let g:yac_remote_tunnels = {}
endfunction

" ================================================================
" Default Configuration
" ================================================================

" Set base directory for scripts (can be overridden by user)
if !exists('g:yac_bridge_base_dir')
  let g:yac_bridge_base_dir = expand('<sfile>:p:h:h:h')
endif

" Initialize remote tunnels storage
if !exists('g:yac_remote_tunnels')
  let g:yac_remote_tunnels = {}
endif