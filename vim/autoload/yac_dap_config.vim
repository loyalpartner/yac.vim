" yac_dap_config.vim — debug.json parsing, config conversion, build steps,
"                       program detection, project root detection
"
" Public API:
"   yac_dap_config#find_project_root()
"   yac_dap_config#debug_config_to_params(cfg, file)   throws 'build_failed'
"   yac_dap_config#pick_debug_config(configs, file)
"   yac_dap_config#detect_program(file, lang)

let s:_pick_configs = []
let s:_pick_file = ''

" ============================================================================
" Project root detection
" ============================================================================

" Walk up from the current file looking for well-known project markers.
function! yac_dap_config#find_project_root() abort
  let dir = expand('%:p:h')
  let markers = ['.git', '.yacd', '.zed', 'Makefile', 'Cargo.toml', 'go.mod', 'build.zig']
  let depth = 0
  while depth < 20 && dir !=# '/' && dir !=# ''
    for marker in markers
      if isdirectory(dir . '/' . marker) || filereadable(dir . '/' . marker)
        return dir
      endif
    endfor
    let dir = fnamemodify(dir, ':h')
    let depth += 1
  endwhile
  return expand('%:p:h')
endfunction

" ============================================================================
" Config conversion
" ============================================================================

" Map Zed adapter names to internal language keys.
function! s:adapter_name_to_lang(name) abort
  let map = {
        \ 'CodeLLDB': 'c', 'codelldb': 'c',
        \ 'Debugpy': 'python', 'debugpy': 'python',
        \ 'Delve': 'go', 'delve': 'go',
        \ 'GDB': 'c', 'gdb': 'c',
        \ 'lldb-dap': 'c',
        \ 'js-debug': 'javascript',
        \ }
  return get(map, a:name, tolower(a:name))
endfunction

" Convert a debug.json config entry to params dict for s:do_start().
" Throws 'build_failed' if the pre-debug build step fails.
function! yac_dap_config#debug_config_to_params(cfg, file) abort
  let params = {}

  let params.request = get(a:cfg, 'request', 'launch')

  if has_key(a:cfg, 'program')
    let params.program = a:cfg.program
  endif

  if has_key(a:cfg, 'module')
    let params.module = a:cfg.module
  endif

  if has_key(a:cfg, 'cwd')
    let params.cwd = a:cfg.cwd
  else
    let params.cwd = yac_dap_config#find_project_root()
  endif

  if has_key(a:cfg, 'args')
    let params.args = copy(a:cfg.args)
  endif

  if has_key(a:cfg, 'env')
    let params.env = a:cfg.env
  endif

  if has_key(a:cfg, 'stopOnEntry')
    let params.stop_on_entry = a:cfg.stopOnEntry
  endif

  if has_key(a:cfg, 'pid')
    let params.pid = a:cfg.pid
  endif

  " Resolve adapter command/args from adapter name
  if has_key(a:cfg, 'adapter')
    let lang = s:adapter_name_to_lang(a:cfg.adapter)
    let adapter = yac_dap_adapter#resolve(lang)
    if !empty(adapter)
      let resolved = yac_dap_adapter#resolve_command(lang, adapter)
      if !empty(resolved)
        let params.adapter_command = resolved.command
        let params.adapter_args = resolved.args
      endif
    endif
  endif

  " Collect adapter-specific extra fields (everything not in standard keys)
  let standard_keys = ['label', 'adapter', 'request', 'program', 'module',
        \ 'cwd', 'args', 'env', 'stopOnEntry', 'pid', 'build']
  let extra = {}
  for [k, v] in items(a:cfg)
    if index(standard_keys, k) < 0
      let extra[k] = v
    endif
  endfor
  if !empty(extra)
    let params.extra = extra
  endif

  if has_key(a:cfg, 'build')
    call s:run_build_step(a:cfg.build)
  endif

  return params
endfunction

" Run a pre-debug build step (string command or {command, args} dict).
" Throws 'build_failed' on failure.
function! s:run_build_step(build) abort
  if type(a:build) == v:t_string
    echohl Comment | echo printf('[yac] Building: %s', a:build) | echohl None
    let output = system(a:build)
    if v:shell_error
      echohl ErrorMsg | echo printf('[yac] Build failed: %s', output) | echohl None
      throw 'build_failed'
    endif
  elseif type(a:build) == v:t_dict
    let cmd = get(a:build, 'command', '')
    let args = get(a:build, 'args', [])
    let full_cmd = cmd . ' ' . join(args, ' ')
    echohl Comment | echo printf('[yac] Building: %s', full_cmd) | echohl None
    let output = system(full_cmd)
    if v:shell_error
      echohl ErrorMsg | echo printf('[yac] Build failed: %s', output) | echohl None
      throw 'build_failed'
    endif
  endif
endfunction

" ============================================================================
" Config picker (popup)
" ============================================================================

" Show a popup_menu to pick one of multiple debug configs, then continue start.
function! yac_dap_config#pick_debug_config(configs, file) abort
  let labels = []
  for cfg in a:configs
    call add(labels, get(cfg, 'label', get(cfg, 'adapter', '?')))
  endfor

  let s:_pick_configs = a:configs
  let s:_pick_file = a:file
  call popup_menu(labels, {
        \ 'title': ' Select debug configuration ',
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        \ 'borderhighlight': ['YacDapBorder'],
        \ 'highlight': 'YacDapNormal',
        \ 'padding': [0,1,0,1],
        \ 'maxwidth': 60,
        \ 'maxheight': 20,
        \ 'callback': function('s:pick_config_callback'),
        \ })
endfunction

function! s:pick_config_callback(id, result) abort
  if a:result < 1
    return
  endif
  let cfg = s:_pick_configs[a:result - 1]
  let file = s:_pick_file
  try
    let config = yac_dap_config#debug_config_to_params(cfg, file)
    call yac_dap#_start_with_config(file, config)
  catch /build_failed/
  endtry
endfunction

" ============================================================================
" Program detection (compiled languages)
" ============================================================================

" Auto-detect the program binary for compiled languages.
function! yac_dap_config#detect_program(file, lang) abort
  if a:lang ==# 'c' || a:lang ==# 'cpp'
    return s:detect_c_binary(a:file)
  elseif a:lang ==# 'zig'
    return s:detect_zig_binary(a:file)
  elseif a:lang ==# 'rust'
    return s:detect_rust_binary(a:file)
  elseif a:lang ==# 'go'
    return a:file
  endif
  return ''
endfunction

function! s:detect_c_binary(file) abort
  let base = fnamemodify(a:file, ':r')
  if filereadable(base) && !isdirectory(base)
    return base
  endif

  let root = yac_dap_config#find_project_root()
  let name = fnamemodify(a:file, ':t:r')
  for dir in ['build', 'bin', 'out']
    let candidate = root . '/' . dir . '/' . name
    if filereadable(candidate) && !isdirectory(candidate)
      return candidate
    endif
  endfor

  return input('[yac] Program binary path: ', root . '/', 'file')
endfunction

function! s:detect_zig_binary(file) abort
  let root = yac_dap_config#find_project_root()
  let zig_out = root . '/zig-out/bin'
  if isdirectory(zig_out)
    let bins = globpath(zig_out, '*', 0, 1)
    let executables = filter(bins, {_, v -> !isdirectory(v) && executable(v)})
    if len(executables) == 1
      return executables[0]
    elseif len(executables) > 1
      let names = map(copy(executables), {_, v -> fnamemodify(v, ':t')})
      let choice = inputlist(['Select binary:'] + map(copy(names), {i, v -> printf('%d. %s', i+1, v)}))
      if choice > 0 && choice <= len(executables)
        return executables[choice - 1]
      endif
    endif
  endif

  return input('[yac] Program binary path: ', root . '/', 'file')
endfunction

function! s:detect_rust_binary(file) abort
  let root = yac_dap_config#find_project_root()

  let cargo_toml = root . '/Cargo.toml'
  if filereadable(cargo_toml)
    let lines = readfile(cargo_toml, '', 30)
    for line in lines
      let m = matchstr(line, '^\s*name\s*=\s*"\zs[^"]*\ze"')
      if !empty(m)
        let debug_bin = root . '/target/debug/' . m
        if filereadable(debug_bin)
          return debug_bin
        endif
        let release_bin = root . '/target/release/' . m
        if filereadable(release_bin)
          return release_bin
        endif
        break
      endif
    endfor
  endif

  return input('[yac] Program binary path: ', root . '/', 'file')
endfunction
