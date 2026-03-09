" yac_remote.vim - SSH Master architecture for remote editing
" Uses SSH ControlMaster for direct stdio connection to remote yacd

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
  elseif get(b:, 'yac_lsp_supported', 0)
    " Local LSP file - use standard mode
    call yac#start()
    " Retry language loading now that the channel is open.
    " ensure_language may have been called before yac#start() (channel not
    " ready), so the load_language request was never sent.
    if exists('b:yac_lang_dir')
      call yac#ensure_language(b:yac_lang_dir)
    endif
    call yac#open_file()
  endif

  return 1
endfunction

" Start SSH Master mode - simplified without blocking
function! s:start_ssh_master_mode(ssh_path) abort
  " Parse SSH path: scp://user@host//path/file
  let [l:user_host, l:remote_path] = s:parse_ssh_path(a:ssh_path)

  " Deploy yacd binary if needed
  call s:ensure_remote_binary(l:user_host)

  echo printf("Starting remote LSP for %s...", l:user_host)
  
  " Set up buffer variables for connection pool
  let b:yac_original_ssh_path = a:ssh_path
  let b:yac_real_path_for_lsp = l:remote_path
  let b:yac_ssh_host = l:user_host
  
  " 连接池会自动管理 SSH 连接，无需手动创建 Master
  " Start LSP - connection pool will handle SSH automatically
  if yac#start()
    if exists('b:yac_lang_dir')
      call yac#ensure_language(b:yac_lang_dir)
    endif
    call yac#open_file()
    return 1
  else
    echoerr printf("Failed to start remote LSP for %s", l:user_host)
    return 0
  endif
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

" Deploy yacd binary to remote host (simplified)
function! s:ensure_remote_binary(user_host) abort
  " Check if already exists
  if system(printf('ssh %s "test -x ./yacd"', shellescape(a:user_host))) == 0
    return 1
  endif

  " Build if needed
  if !filereadable('./zig-out/bin/yacd')
    echo "Building yacd..."
    call system('zig build -Doptimize=ReleaseFast')
  endif

  " Deploy
  echo "Deploying to " . a:user_host . "..."
  call system(printf('scp ./zig-out/bin/yacd %s:yacd', shellescape(a:user_host)))
  call system(printf('ssh %s "chmod +x yacd"', shellescape(a:user_host)))

  return 1
endfunction
