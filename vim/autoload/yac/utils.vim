" Utility functions for yac.vim
" Common helper functions used across modules

" 获取当前单词前缀（用于补全）
function! yac#utils#get_current_word_prefix() abort
  let l:current_line = getline('.')
  let l:col = col('.')
  let l:before_cursor = strpart(l:current_line, 0, l:col - 1)
  
  " 使用更精确的模式匹配，支持更多字符
  let l:match = matchstr(l:before_cursor, '\w*$')
  return l:match
endfunction

" 检查是否在字符串或注释中
function! yac#utils#in_string_or_comment() abort
  let l:synname = synIDattr(synID(line('.'), col('.'), 1), 'name')
  return l:synname =~? 'string\|comment'
endfunction

" 查找工作区根目录
function! yac#utils#find_workspace_root() abort
  let l:current_dir = expand('%:p:h')
  if empty(l:current_dir)
    let l:current_dir = getcwd()
  endif

  " 查找常见的项目根标识
  let l:root_markers = ['.git', '.svn', '.hg', 'Cargo.toml', 'package.json', 'go.mod', 'Makefile', '.project']
  
  let l:dir = l:current_dir
  while l:dir != '/' && l:dir != ''
    for l:marker in l:root_markers
      if isdirectory(l:dir . '/' . l:marker) || filereadable(l:dir . '/' . l:marker)
        return l:dir
      endif
    endfor
    let l:parent = fnamemodify(l:dir, ':h')
    if l:parent == l:dir
      break
    endif
    let l:dir = l:parent
  endwhile

  return l:current_dir
endfunction

" 获取文件类型对应的LSP语言ID
function! yac#utils#get_language_id() abort
  let l:ft = &filetype
  
  " 常见文件类型映射
  let l:language_map = {
    \ 'c': 'c',
    \ 'cpp': 'cpp',
    \ 'objc': 'objc',
    \ 'objcpp': 'objcpp',
    \ 'python': 'python',
    \ 'java': 'java',
    \ 'javascript': 'javascript',
    \ 'typescript': 'typescript',
    \ 'typescriptreact': 'typescriptreact',
    \ 'javascriptreact': 'javascriptreact',
    \ 'go': 'go',
    \ 'rust': 'rust',
    \ 'php': 'php',
    \ 'ruby': 'ruby',
    \ 'sh': 'shellscript',
    \ 'bash': 'shellscript',
    \ 'zsh': 'shellscript',
    \ 'fish': 'shellscript',
    \ 'vim': 'vim',
    \ 'lua': 'lua',
    \ 'perl': 'perl',
    \ 'html': 'html',
    \ 'css': 'css',
    \ 'scss': 'scss',
    \ 'less': 'less',
    \ 'json': 'json',
    \ 'yaml': 'yaml',
    \ 'toml': 'toml',
    \ 'xml': 'xml',
    \ 'markdown': 'markdown',
    \ 'tex': 'latex',
    \ 'r': 'r',
    \ 'julia': 'julia',
    \ 'haskell': 'haskell',
    \ 'scala': 'scala',
    \ 'kotlin': 'kotlin',
    \ 'dart': 'dart',
    \ 'swift': 'swift'
    \ }

  return get(l:language_map, l:ft, l:ft)
endfunction

" 规范化文件路径
function! yac#utils#normalize_path(path) abort
  let l:path = a:path
  
  " 展开 ~ 和环境变量
  let l:path = expand(l:path)
  
  " 转换为绝对路径
  if !empty(l:path) && l:path[0] != '/'
    let l:path = fnamemodify(l:path, ':p')
  endif
  
  " 移除末尾的斜杠（除了根目录）
  if len(l:path) > 1 && l:path[-1:] == '/'
    let l:path = l:path[:-2]
  endif
  
  return l:path
endfunction

" 获取相对于工作区的文件路径
function! yac#utils#get_relative_path(file_path) abort
  let l:workspace_root = yac#utils#find_workspace_root()
  let l:file_path = yac#utils#normalize_path(a:file_path)
  
  if stridx(l:file_path, l:workspace_root) == 0
    let l:relative = l:file_path[len(l:workspace_root):]
    " 移除开头的斜杠
    if !empty(l:relative) && l:relative[0] == '/'
      let l:relative = l:relative[1:]
    endif
    return l:relative
  endif
  
  return l:file_path
endfunction

" 创建LSP位置对象
function! yac#utils#create_lsp_position(line, character) abort
  return {
    \ 'line': a:line,
    \ 'character': a:character
    \ }
endfunction

" 创建LSP范围对象
function! yac#utils#create_lsp_range(start_line, start_char, end_line, end_char) abort
  return {
    \ 'start': yac#utils#create_lsp_position(a:start_line, a:start_char),
    \ 'end': yac#utils#create_lsp_position(a:end_line, a:end_char)
    \ }
endfunction

" 获取当前光标的LSP位置
function! yac#utils#get_cursor_position() abort
  return yac#utils#create_lsp_position(line('.') - 1, col('.') - 1)
endfunction

" 获取当前选择的LSP范围
function! yac#utils#get_visual_range() abort
  let l:start_pos = getpos("'<")
  let l:end_pos = getpos("'>")
  
  return yac#utils#create_lsp_range(
    \ l:start_pos[1] - 1, l:start_pos[2] - 1,
    \ l:end_pos[1] - 1, l:end_pos[2] - 1
    \ )
endfunction

" 格式化文件大小
function! yac#utils#format_file_size(bytes) abort
  let l:bytes = a:bytes
  let l:units = ['B', 'KB', 'MB', 'GB']
  let l:unit_index = 0
  
  while l:bytes >= 1024 && l:unit_index < len(l:units) - 1
    let l:bytes = l:bytes / 1024.0
    let l:unit_index += 1
  endwhile
  
  if l:unit_index == 0
    return printf('%d %s', float2nr(l:bytes), l:units[l:unit_index])
  else
    return printf('%.1f %s', l:bytes, l:units[l:unit_index])
  endif
endfunction

" 截断长文本
function! yac#utils#truncate_text(text, max_length, suffix) abort
  if len(a:text) <= a:max_length
    return a:text
  endif
  
  let l:suffix = empty(a:suffix) ? '...' : a:suffix
  let l:truncate_length = a:max_length - len(l:suffix)
  
  if l:truncate_length <= 0
    return l:suffix
  endif
  
  return a:text[:l:truncate_length - 1] . l:suffix
endfunction

" 检查文件是否为二进制文件
function! yac#utils#is_binary_file(file_path) abort
  if !filereadable(a:file_path)
    return 0
  endif
  
  " 读取文件前几个字节来检测
  let l:sample = system('head -c 512 ' . shellescape(a:file_path))
  
  " 检查是否包含空字节或其他二进制标识
  if stridx(l:sample, "\x00") != -1
    return 1
  endif
  
  " 检查非打印字符的比例
  let l:non_printable = 0
  for l:i in range(len(l:sample))
    let l:char = l:sample[l:i]
    let l:ord = char2nr(l:char)
    if (l:ord < 32 && l:ord != 9 && l:ord != 10 && l:ord != 13) || l:ord > 126
      let l:non_printable += 1
    endif
  endfor
  
  " 如果非打印字符超过30%，认为是二进制文件
  return (l:non_printable * 100 / len(l:sample)) > 30
endfunction

" 创建临时文件
function! yac#utils#create_temp_file(prefix, suffix) abort
  let l:temp_dir = fnamemodify(tempname(), ':h')
  let l:prefix = empty(a:prefix) ? 'yac_' : a:prefix
  let l:suffix = empty(a:suffix) ? '.tmp' : a:suffix
  
  " 生成唯一文件名
  let l:counter = 0
  while l:counter < 1000
    let l:filename = printf('%s%s%d%s', l:prefix, localtime(), l:counter, l:suffix)
    let l:full_path = l:temp_dir . '/' . l:filename
    
    if !filereadable(l:full_path)
      return l:full_path
    endif
    
    let l:counter += 1
  endwhile
  
  " fallback
  return tempname() . l:suffix
endfunction

" 安全删除文件
function! yac#utils#safe_delete_file(file_path) abort
  if empty(a:file_path) || !filereadable(a:file_path)
    return 0
  endif
  
  try
    call delete(a:file_path)
    return 1
  catch
    return 0
  endtry
endfunction

" 获取文件修改时间
function! yac#utils#get_file_mtime(file_path) abort
  if !filereadable(a:file_path)
    return 0
  endif
  
  return getftime(a:file_path)
endfunction

" 比较两个文件的修改时间
function! yac#utils#is_file_newer(file1, file2) abort
  let l:mtime1 = yac#utils#get_file_mtime(a:file1)
  let l:mtime2 = yac#utils#get_file_mtime(a:file2)
  
  return l:mtime1 > l:mtime2
endfunction

" 获取缓冲区内容作为字符串列表
function! yac#utils#get_buffer_lines(bufnr) abort
  if a:bufnr == -1 || !bufexists(a:bufnr)
    return []
  endif
  
  return getbufline(a:bufnr, 1, '$')
endfunction

" 检查缓冲区是否已修改
function! yac#utils#is_buffer_modified(bufnr) abort
  if a:bufnr == -1 || !bufexists(a:bufnr)
    return 0
  endif
  
  return getbufvar(a:bufnr, '&modified')
endfunction