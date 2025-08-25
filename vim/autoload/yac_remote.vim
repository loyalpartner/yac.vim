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
  " Generate unique socket path for this SSH session
  let l:socket_path = '/tmp/yac-ssh-' . substitute(a:user_host, '@', '-', 'g') . '.sock'
  
  " Set environment variable to enable Unix socket mode
  " This tells local lsp-bridge to use Unix socket instead of stdio
  let $YAC_UNIX_SOCKET = l:socket_path
  
  " TODO: In complete implementation, we would:
  " 1. Deploy lsp-bridge binary to remote host via scp
  " 2. Start remote lsp-bridge server: ssh user@host 'lsp-bridge --socket /tmp/yac-remote.sock'
  " 3. Create SSH tunnel: ssh -L local_socket:remote_socket user@host
  " 4. Local bridge will forward messages through the tunnel
  
  echo "Remote mode enabled. Socket: " . l:socket_path
  echo "User@Host: " . a:user_host . " Path: " . a:remote_path
endfunction

" Placeholder for future tunnel cleanup
function! yac_remote#cleanup_tunnels() abort
  " Nothing to clean up in simplified version
endfunction