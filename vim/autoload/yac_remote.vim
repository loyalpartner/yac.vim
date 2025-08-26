" yac_remote.vim - SSH Master architecture for remote editing
" Uses SSH ControlMaster for direct stdio connection to remote lsp-bridge

if exists('g:loaded_yac_remote')
  finish
endif
let g:loaded_yac_remote = 1

" Enhanced smart LSP start that detects SSH files
function! yac_remote#enhanced_lsp_start() abort
  let l:filepath = expand('%:p')
  
  " Check if this is an SSH file (scp:// or ssh:// protocol)
  if l:filepath =~# '^s\(cp\|sh\)://'
    echo "SSH file detected: " . l:filepath
    call s:start_ssh_master_mode(l:filepath)
  else
    " Local file - use standard mode
    call yac#start()
    call yac#open_file()
  endif
  
  return 1
endfunction

" Start SSH Master mode with proper 2-step flow
function! s:start_ssh_master_mode(ssh_path) abort
  " Parse SSH path: scp://user@host//path/file
  let [l:user_host, l:remote_path] = s:parse_ssh_path(a:ssh_path)
  
  " Deploy lsp-bridge binary if needed
  call s:ensure_remote_binary(l:user_host)
  
  " Step 1: Create SSH Master tunnel 
  let l:control_path = '/tmp/yac-' . substitute(l:user_host, '[^a-zA-Z0-9]', '_', 'g') . '.sock'
  echo "Creating SSH Master tunnel to " . l:user_host . "..."
  call system(printf('ssh -N -o ControlMaster=yes -o ControlPath=%s %s &', 
    \ shellescape(l:control_path), shellescape(l:user_host)))
  
  " Wait for master connection to establish
  sleep 500m
  
  " Step 2: Set up SSH Master connection info
  let $YAC_SSH_HOST = l:user_host
  let $YAC_SSH_CONTROL_PATH = l:control_path
  
  " Set up path conversion for LSP
  let b:yac_original_ssh_path = a:ssh_path
  let b:yac_real_path_for_lsp = l:remote_path
  let b:yac_ssh_host = l:user_host
  let b:yac_ssh_control_path = l:control_path
  
  echo "SSH Master tunnel established for " . l:user_host
  
  " Step 3: Start yac with SSH Master job command
  call yac#start()
  call yac#open_file()
endfunction

" Parse SSH path into user@host and remote path
function! s:parse_ssh_path(ssh_path) abort
  let l:match = matchlist(a:ssh_path, '^s\(cp\|sh\)://\([^@]\+@[^/]\+\)\(//\?\(.*\)\)')
  if empty(l:match)
    echoerr "Invalid SSH path format: " . a:ssh_path
    return ['', '']
  endif
  
  let l:user_host = l:match[2]
  let l:remote_path = l:match[4]
  if l:remote_path !~# '^/'
    let l:remote_path = '/' . l:remote_path
  endif
  
  return [l:user_host, l:remote_path]
endfunction

" Deploy lsp-bridge binary to remote host (simplified)
function! s:ensure_remote_binary(user_host) abort
  " Check if already exists
  if system(printf('ssh %s "test -x ./lsp-bridge"', shellescape(a:user_host))) == 0
    return 1
  endif
  
  " Build if needed
  if !filereadable('./target/release/lsp-bridge')
    echo "Building lsp-bridge..."
    call system('cargo build --release')
  endif
  
  " Deploy
  echo "Deploying to " . a:user_host . "..."
  call system(printf('scp ./target/release/lsp-bridge %s:lsp-bridge', shellescape(a:user_host)))
  call system(printf('ssh %s "chmod +x lsp-bridge"', shellescape(a:user_host)))
  
  return 1
endfunction

" Get file path for LSP operations - returns converted path for SSH files
function! yac_remote#get_lsp_file_path() abort
  return exists('b:yac_real_path_for_lsp') ? b:yac_real_path_for_lsp : expand('%:p')
endfunction

" Get job command - returns SSH Master command for SSH files
function! yac_remote#get_job_command() abort
  " Check if this is SSH mode with ControlPath
  if exists('b:yac_ssh_host') && exists('b:yac_ssh_control_path')
    " Return SSH Master command: ssh -o ControlPath=... user@host lsp-bridge
    return ['ssh', '-o', 'ControlPath=' . b:yac_ssh_control_path, b:yac_ssh_host, 'lsp-bridge']
  endif
  
  " Local mode - return default command
  return get(g:, 'yac_bridge_command', ['./target/release/lsp-bridge'])
endfunction

" Cleanup command for SSH Master tunnels
function! yac_remote#cleanup() abort
  echo "Cleaning up SSH Master tunnels..."
  call system('pkill -f "ssh.*ControlMaster.*yac-.*\.sock" || true')
  call system('rm -f /tmp/yac-*.sock')
  unlet! $YAC_SSH_HOST $YAC_SSH_CONTROL_PATH
  echo "SSH Master cleanup complete"
endfunction