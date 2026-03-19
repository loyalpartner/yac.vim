" yac_dap_adapter.vim — Adapter configuration, resolution, installation, venv detection
"
" Public API:
"   yac_dap_adapter#ext_to_lang(ext)
"   yac_dap_adapter#resolve(lang)
"   yac_dap_adapter#resolve_command(lang, adapter)
"   yac_dap_adapter#available(lang, adapter)
"   yac_dap_adapter#find_venv_python()
"   yac_dap_adapter#install(lang, adapter, file, config)
"   yac_dap_adapter#is_python_test(file)

let s:data_dir = $HOME . '/.local/share/yac'

" Adapter install configs — parallel to yac_install.vim pip method
let s:adapter_configs = {
      \ 'python': {
      \   'command': 'python3', 'args': ['-m', 'debugpy.adapter'],
      \   'install': {'method': 'pip', 'package': 'debugpy', 'bin_name': 'debugpy'},
      \ },
      \ 'c': {
      \   'command': 'codelldb', 'args': [],
      \   'install': {'method': 'github_release', 'bin_name': 'codelldb',
      \     'repo': 'vadimcn/codelldb',
      \     'asset': 'codelldb-{PLATFORM}-{VSARCH}.vsix',
      \     'platform_map': {'Linux': 'linux', 'Darwin': 'darwin'},
      \     'arch_map': {'x86_64': 'x64', 'aarch64': 'arm64'},
      \     'binary_path': 'extension/adapter/codelldb'},
      \ },
      \ 'cpp':        'c',
      \ 'zig':        'c',
      \ 'rust':       'c',
      \ 'go': {
      \   'command': 'dlv', 'args': ['dap'],
      \   'install': {'method': 'github_release', 'bin_name': 'dlv',
      \     'repo': 'go-delve/delve',
      \     'asset': 'dlv_{PLATFORM}_{GOARCH}',
      \     'platform_map': {'Linux': 'linux', 'Darwin': 'darwin'}},
      \ },
      \ 'javascript': {
      \   'command': 'node', 'args': [],
      \   'install': {'method': 'github_release', 'bin_name': 'js-debug',
      \     'repo': 'microsoft/vscode-js-debug',
      \     'asset': 'js-debug-dap-v{VERSION}.tar.gz',
      \     'platform_map': {'Linux': 'linux', 'Darwin': 'darwin'},
      \     'binary_path': 'js-debug/src/dapDebugServer.js'},
      \ },
      \ 'typescript': 'javascript',
      \ }

" Map file extension to language key.
function! yac_dap_adapter#ext_to_lang(ext) abort
  let map = {
        \ 'py': 'python',
        \ 'c': 'c', 'h': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp',
        \ 'hpp': 'cpp', 'hxx': 'cpp',
        \ 'zig': 'zig', 'rs': 'rust', 'go': 'go',
        \ 'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
        \ 'ts': 'typescript', 'mts': 'typescript', 'cts': 'typescript',
        \ }
  return get(map, a:ext, a:ext)
endfunction

" Resolve adapter config dict for a language (follow string aliases).
function! yac_dap_adapter#resolve(lang) abort
  if !has_key(s:adapter_configs, a:lang)
    return {}
  endif
  let cfg = s:adapter_configs[a:lang]
  if type(cfg) == v:t_string
    return has_key(s:adapter_configs, cfg) ? s:adapter_configs[cfg] : {}
  endif
  return cfg
endfunction

" Get the resolved command path for an adapter (managed or system).
" Returns {'command': ..., 'args': [...]} or {} if not available.
function! yac_dap_adapter#resolve_command(lang, adapter) abort
  let info = get(a:adapter, 'install', {})
  let bin_name = get(info, 'bin_name', '')

  " --- Python (debugpy): check venv → managed → system ---
  if a:lang ==# 'python'
    let venv_py = yac_dap_adapter#find_venv_python()
    if !empty(venv_py)
      if system(venv_py . ' -c "import debugpy"') ==# '' && v:shell_error == 0
        return {'command': venv_py, 'args': ['-m', 'debugpy.adapter']}
      endif
    endif
    let managed_py = s:data_dir . '/packages/debugpy/venv/bin/python3'
    if filereadable(managed_py)
      if system(managed_py . ' -c "import debugpy"') ==# '' && v:shell_error == 0
        return {'command': managed_py, 'args': ['-m', 'debugpy.adapter']}
      endif
    endif
    if system('python3 -c "import debugpy"') ==# '' && v:shell_error == 0
      return {'command': 'python3', 'args': ['-m', 'debugpy.adapter']}
    endif
    return {}
  endif

  " --- js-debug: node + dapDebugServer.js ---
  if bin_name ==# 'js-debug'
    let binary_path = get(info, 'binary_path', '')
    let js_bin = s:data_dir . '/packages/js-debug/' . binary_path
    if filereadable(js_bin) && executable('node')
      return {'command': 'node', 'args': [js_bin]}
    endif
    return {}
  endif

  " --- Binary adapters (codelldb, dlv): managed → system ---
  if !empty(bin_name)
    let binary_path = get(info, 'binary_path', 'bin/' . bin_name)
    let managed_bin = s:data_dir . '/packages/' . bin_name . '/' . binary_path
    if filereadable(managed_bin)
      return {'command': managed_bin, 'args': get(a:adapter, 'args', [])}
    endif
  endif

  " System PATH
  let cmd = get(a:adapter, 'command', '')
  if !empty(cmd) && executable(cmd)
    return {'command': cmd, 'args': get(a:adapter, 'args', [])}
  endif
  return {}
endfunction

" Return 1 if the adapter is available (resolvable to a command), 0 otherwise.
function! yac_dap_adapter#available(lang, adapter) abort
  return !empty(yac_dap_adapter#resolve_command(a:lang, a:adapter))
endfunction

" Walk up the directory tree looking for a venv Python interpreter.
function! yac_dap_adapter#find_venv_python() abort
  let dir = expand('%:p:h')
  let depth = 0
  while depth < 10 && dir !=# '/' && dir !=# ''
    for venv in ['.venv', 'venv']
      let py = dir . '/' . venv . '/bin/python3'
      if filereadable(py)
        return py
      endif
    endfor
    let dir = fnamemodify(dir, ':h')
    let depth += 1
  endwhile
  return ''
endfunction

" Delegate adapter installation to yac_install#run; saves pending start context.
function! yac_dap_adapter#install(lang, adapter, file, config) abort
  let info = a:adapter.install
  let g:_yac_dap_install_pending = {'file': a:file, 'config': a:config}
  call yac_install#run(a:lang, info)
endfunction

" Return 1 if the file is a Python test file that uses pytest.
function! yac_dap_adapter#is_python_test(file) abort
  if fnamemodify(a:file, ':e') !=# 'py'
    return 0
  endif
  let fname = fnamemodify(a:file, ':t')
  if fname !~# '^test_' && fname !~# '_test\.py$'
    return 0
  endif
  let content = join(getline(1, min([50, line('$')])), "\n")
  return content =~# '\<import pytest\>\|from pytest '
endfunction
