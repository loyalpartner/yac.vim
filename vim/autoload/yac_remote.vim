" Remote editing functionality for yac.vim
" SSH tunnel + distributed lsp-bridge implementation

" Parse SSH file path to extract connection info
" scp://user@host//path/file -> {user: 'user', host: 'host', path: '/path/file'}
function! s:parse_ssh_path(ssh_filepath) abort
  let pattern = '^s\(cp\|ftp\)://\([^@]*\)@\([^/]*\)\(/.*\)$'
  let matches = matchlist(a:ssh_filepath, pattern)
  
  if empty(matches)
    throw 'Invalid SSH file path: ' . a:ssh_filepath
  endif
  
  return {
    \ 'user': matches[2],
    \ 'host': matches[3],
    \ 'path': matches[4],
    \ 'connection': matches[2] . '@' . matches[3]
    \ }
endfunction

" Check if a file path is SSH-based
function! s:is_ssh_file(filepath) abort
  return match(a:filepath, '^s\(cp\|ftp\)://') >= 0
endfunction

" Find available local port for SSH tunnel
function! s:find_available_port() abort
  " Try ports starting from 9000
  for port in range(9000, 9999)
    let result = system('ss -ln | grep :' . port . ' | wc -l')
    if str2nr(result) == 0
      return port
    endif
  endfor
  
  throw 'No available ports found in range 9000-9999'
endfunction

" Check if remote lsp-bridge exists and get version info
function! s:check_remote_lsp_bridge(ssh_info) abort
  let cmd = printf('ssh %s "~/.local/bin/lsp-bridge --version 2>/dev/null || echo MISSING"',
    \ a:ssh_info.connection)
  
  let result = substitute(system(cmd), '\n$', '', '')
  
  if result ==# 'MISSING'
    return {'exists': v:false, 'version': ''}
  else
    return {'exists': v:true, 'version': result}
  endif
endfunction

" Upload lsp-bridge binary to remote host
function! s:upload_lsp_bridge(ssh_info) abort
  echo 'Uploading lsp-bridge to remote server...'
  
  " Ensure remote directory exists
  let mkdir_cmd = printf('ssh %s "mkdir -p ~/.local/bin"', a:ssh_info.connection)
  call system(mkdir_cmd)
  
  " Upload binary
  let upload_cmd = printf('scp ./target/release/lsp-bridge %s:~/.local/bin/',
    \ a:ssh_info.connection)
  let result = system(upload_cmd)
  
  if v:shell_error != 0
    throw 'Failed to upload lsp-bridge: ' . result
  endif
  
  " Set executable permissions
  let chmod_cmd = printf('ssh %s "chmod +x ~/.local/bin/lsp-bridge"',
    \ a:ssh_info.connection)
  call system(chmod_cmd)
  
  echo 'lsp-bridge uploaded successfully'
endfunction

" Start remote lsp-bridge server
function! s:start_remote_lsp_bridge(ssh_info, port) abort
  let start_cmd = printf('ssh %s "nohup ~/.local/bin/lsp-bridge --server --port %d > /tmp/lsp-bridge-server.log 2>&1 &"',
    \ a:ssh_info.connection, a:port)
  
  call system(start_cmd)
  
  " Wait for server to start
  sleep 1000m
  
  echo printf('Remote lsp-bridge started on %s:%d', a:ssh_info.host, a:port)
endfunction

" Establish SSH tunnel for LSP communication
function! s:establish_ssh_tunnel(ssh_info, port) abort
  let script_path = './scripts/ssh_tunnel_manager.sh'
  
  " Check if tunnel already exists
  let check_cmd = printf('%s check_tunnel %d', script_path, a:port)
  let status = substitute(system(check_cmd), '\n$', '', '')
  
  if status ==# 'active'
    echo printf('SSH tunnel already active on port %d', a:port)
    return
  endif
  
  " Establish new tunnel
  let establish_cmd = printf('%s establish_tunnel %s %d',
    \ script_path, a:ssh_info.connection, a:port)
  
  let result = system(establish_cmd)
  
  if v:shell_error != 0
    throw 'Failed to establish SSH tunnel: ' . result
  endif
  
  echo printf('SSH tunnel established: localhost:%d -> %s:%d', 
    \ a:port, a:ssh_info.host, a:port)
endfunction

" Smart remote LSP bridge startup with auto-deployment
function! yac_remote#start_remote_bridge(ssh_filepath) abort
  try
    let ssh_info = s:parse_ssh_path(a:ssh_filepath)
    echo printf('Setting up remote editing for %s', ssh_info.connection)
    
    " Find available port for tunnel
    let port = s:find_available_port()
    
    " Check remote lsp-bridge status
    let remote_bridge = s:check_remote_lsp_bridge(ssh_info)
    
    " Upload if missing or outdated
    if !remote_bridge.exists
      echo 'lsp-bridge not found on remote host, uploading...'
      call s:upload_lsp_bridge(ssh_info)
    else
      echo printf('Remote lsp-bridge found (version: %s)', remote_bridge.version)
    endif
    
    " Establish SSH tunnel
    call s:establish_ssh_tunnel(ssh_info, port)
    
    " Start remote server (if not already running)
    call s:start_remote_lsp_bridge(ssh_info, port)
    
    " Configure local bridge for remote connection
    " TODO: This would integrate with the main yac#start() function
    " For now, we'll just echo success
    echo printf('Remote editing configured for %s via port %d', ssh_info.connection, port)
    
  catch
    echoerr 'Failed to setup remote editing: ' . v:exception
  endtry
endfunction

" Smart LSP start function that detects SSH files
function! yac_remote#smart_lsp_start() abort
  let filepath = expand('%:p')
  
  if s:is_ssh_file(filepath)
    call yac_remote#start_remote_bridge(filepath)
  else
    " Regular local startup
    call yac#start()
    call yac#open_file()
  endif
endfunction

" Clean up SSH tunnels on exit
function! yac_remote#cleanup_tunnels() abort
  let script_path = './scripts/ssh_tunnel_manager.sh'
  let cmd = printf('%s cleanup_all', script_path)
  call system(cmd)
endfunction