" yac_remote.vim - Simplified SSH remote editing support
" Uses three-mode architecture: local bridge -> SSH tunnel -> remote bridge

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
    call s:start_ssh_mode(l:filepath)
  else
    " Local file - use standard mode
    call yac#start()
    call yac#open_file()
  endif
  
  return 1
endfunction

" Start SSH mode with simplified 3-step flow
function! s:start_ssh_mode(ssh_path) abort
  " Parse SSH path: scp://user@host//path/file
  let [l:user_host, l:remote_path] = s:parse_ssh_path(a:ssh_path)
  
  " Step 1: Deploy and start remote lsp-bridge server
  call s:ensure_remote_binary(l:user_host)
  let l:remote_socket = '/tmp/yac-remote.sock'
  call system(printf('ssh -f %s "YAC_UNIX_SOCKET=%s ./lsp-bridge"', 
    \ shellescape(l:user_host), shellescape(l:remote_socket)))
  
  " Step 2: Create SSH tunnel (Unix socket forwarding)
  let l:local_socket = '/tmp/yac-local.sock'
  call system(printf('ssh -f -N -L %s:%s %s', 
    \ shellescape(l:local_socket), shellescape(l:remote_socket), shellescape(l:user_host)))
  
  " Step 3: Set up local forwarder mode and start
  let $YAC_REMOTE_SOCKET = l:local_socket
  let $YAC_SSH_HOST = l:user_host
  
  " Set up path conversion for LSP
  let b:yac_original_ssh_path = a:ssh_path
  let b:yac_real_path_for_lsp = l:remote_path
  
  echo "SSH tunnel established for " . l:user_host
  
  " Start yac in forwarder mode (due to YAC_REMOTE_SOCKET env var)
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

" Cleanup command for manual tunnel management
function! yac_remote#cleanup() abort
  echo "Cleaning up SSH tunnels..."
  call system('pkill -f "ssh.*-L.*yac-.*\.sock" || true')
  call system('rm -f /tmp/yac-local.sock')
  unlet! $YAC_REMOTE_SOCKET $YAC_SSH_HOST
  echo "SSH cleanup complete"
endfunction