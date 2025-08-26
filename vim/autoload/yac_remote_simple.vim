" yac_remote_simple.vim - SSH Master技术简化实现
" 使用SSH ControlPath直接连接，消除复杂的隧道架构

if exists('g:loaded_yac_remote_simple')
  finish
endif
let g:loaded_yac_remote_simple = 1

" SSH Master模式的LSP启动函数
function! yac_remote_simple#enhanced_lsp_start() abort
  let l:filepath = expand('%:p')
  
  " 检测SSH文件格式
  if l:filepath =~# '^scp://'
    echo "SSH file detected: " . l:filepath
    call s:setup_ssh_mode(l:filepath)
  endif
  
  " 使用统一的启动流程 - job_start会根据SSH配置选择命令
  call yac#start()
  call yac#open_file()
  
  return 1
endfunction

" 设置SSH模式的缓冲区变量
function! s:setup_ssh_mode(ssh_path) abort
  " 解析SSH路径: scp://user@host//path/file
  let [l:user_host, l:remote_path] = s:parse_ssh_path(a:ssh_path)
  
  if empty(l:user_host) || empty(l:remote_path)
    echoerr "Failed to parse SSH path: " . a:ssh_path
    return
  endif
  
  " 确保远程有lsp-bridge二进制
  call s:ensure_remote_binary(l:user_host)
  
  " 设置缓冲区变量供yac#start()使用
  let b:yac_ssh_host = l:user_host
  let b:yac_original_ssh_path = a:ssh_path
  let b:yac_real_path_for_lsp = l:remote_path
  
  echo "SSH mode configured for " . l:user_host
endfunction

" 解析SSH路径格式
function! s:parse_ssh_path(ssh_path) abort
  let l:match = matchlist(a:ssh_path, '^scp://\([^@]\+@[^/]\+\)\(//\?\(.*\)\)')
  if empty(l:match)
    return ['', '']
  endif
  
  let l:user_host = l:match[1]
  let l:remote_path = l:match[3]
  if l:remote_path !~# '^/'
    let l:remote_path = '/' . l:remote_path
  endif
  
  return [l:user_host, l:remote_path]
endfunction

" 确保远程主机有lsp-bridge二进制文件
function! s:ensure_remote_binary(user_host) abort
  " 检查远程是否已有lsp-bridge
  let l:check_cmd = printf('ssh %s "test -x ./lsp-bridge"', shellescape(a:user_host))
  if system(l:check_cmd) == 0
    return 1  " 已存在
  endif
  
  " 构建本地二进制（如果需要）
  if !filereadable('./target/release/lsp-bridge')
    echo "Building lsp-bridge..."
    let l:build_result = system('cargo build --release')
    if v:shell_error != 0
      echoerr "Failed to build lsp-bridge: " . l:build_result
      return 0
    endif
  endif
  
  " 部署到远程
  echo "Deploying lsp-bridge to " . a:user_host . "..."
  let l:scp_cmd = printf('scp ./target/release/lsp-bridge %s:lsp-bridge', shellescape(a:user_host))
  let l:scp_result = system(l:scp_cmd)
  
  if v:shell_error != 0
    echoerr "Failed to deploy lsp-bridge: " . l:scp_result
    return 0
  endif
  
  " 设置执行权限
  let l:chmod_cmd = printf('ssh %s "chmod +x lsp-bridge"', shellescape(a:user_host))
  call system(l:chmod_cmd)
  
  return 1
endfunction

" 获取LSP文件路径 - 对SSH文件返回转换后的普通路径
function! yac_remote_simple#get_lsp_file_path() abort
  return exists('b:yac_real_path_for_lsp') ? b:yac_real_path_for_lsp : expand('%:p')
endfunction

" 获取SSH Master连接的job命令
function! yac_remote_simple#get_job_command() abort
  if exists('b:yac_ssh_host')
    " SSH模式: 使用SSH Master直连
    let l:control_path = '/tmp/yac-' . substitute(b:yac_ssh_host, '[^a-zA-Z0-9]', '_', 'g') . '.sock'
    return ['ssh', '-o', 'ControlPath=' . l:control_path, b:yac_ssh_host, 'lsp-bridge']
  else
    " 本地模式: 使用标准命令
    return get(g:, 'yac_bridge_command', ['./target/release/lsp-bridge'])
  endif
endfunction

" 清理函数（保持向后兼容）
function! yac_remote_simple#cleanup() abort
  echo "Cleaning up SSH connections..."
  " SSH Master连接会自动管理，无需特殊清理
  " 但可以显式关闭master连接
  if exists('b:yac_ssh_host')
    let l:control_path = '/tmp/yac-' . substitute(b:yac_ssh_host, '[^a-zA-Z0-9]', '_', 'g') . '.sock'
    call system('ssh -o ControlPath=' . l:control_path . ' -O exit ' . b:yac_ssh_host . ' 2>/dev/null || true')
  endif
  echo "SSH cleanup complete"
endfunction