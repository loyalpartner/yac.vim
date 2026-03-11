" yac_install.vim — LSP server auto-install and update

let s:data_dir = $HOME . '/.local/share/yac'
let s:bin_dir = s:data_dir . '/bin'
let s:packages_dir = s:data_dir . '/packages'
let s:staging_dir = s:data_dir . '/staging'

" Track ongoing installs to prevent duplicate jobs
let s:installing = {}

" Called by daemon when LSP server spawn fails.
function! yac_install#on_spawn_failed(language, command) abort
  " Look up install info from languages.json (not b: — buffer may have changed)
  let l:install = s:find_language_install(a:language)
  let l:method = get(l:install, 'method', '')

  " system or no install info → show toast
  if empty(l:install) || l:method ==# 'system'
    call yac#toast(printf('LSP "%s" not found for %s', a:command, a:language), {'highlight': 'WarningMsg'})
    return
  endif

  " Already installing this language
  if has_key(s:installing, a:language)
    return
  endif

  if get(g:, 'yac_auto_install_lsp', 1)
    call yac_install#run(a:language, l:install)
    return
  endif

  " Non-blocking toast — user can use command palette (Ctrl-P :) → LSP Install
  call yac#toast(printf('LSP "%s" not found. Use command palette → LSP Install', a:command), {'highlight': 'WarningMsg'})
endfunction

" Execute the installation.
function! yac_install#run(language, install_info) abort
  let l:method = a:install_info.method
  let l:package = get(a:install_info, 'package', '')
  let l:bin_name = get(a:install_info, 'bin_name', '')
  if empty(l:bin_name) && !empty(l:package)
    let l:bin_name = split(l:package, ' ')[0]
    let l:bin_name = split(l:bin_name, '/')[-1]
    " Strip @version suffix
    let l:bin_name = split(l:bin_name, '@')[0]
  endif
  if empty(l:bin_name)
    let l:bin_name = get(a:install_info, 'repo', a:language)
    let l:bin_name = split(l:bin_name, '/')[-1]
  endif

  " Derive package name for directory (without version/path)
  let l:pkg_dir_name = l:bin_name

  let l:staging = s:staging_dir . '/' . l:pkg_dir_name
  let l:dest = s:packages_dir . '/' . l:pkg_dir_name

  " Mark as installing
  let s:installing[a:language] = 1

  " Create staging directory
  call mkdir(l:staging, 'p')

  call yac#toast(printf('Installing %s...', l:bin_name))
  call yac#_install_debug_log(printf('Installing %s via %s', l:bin_name, l:method))

  let l:ctx = {
    \ 'language': a:language,
    \ 'install_info': a:install_info,
    \ 'bin_name': l:bin_name,
    \ 'pkg_dir_name': l:pkg_dir_name,
    \ 'staging': l:staging,
    \ 'dest': l:dest,
    \ }

  if l:method ==# 'npm'
    call s:install_npm(l:ctx)
  elseif l:method ==# 'pip'
    call s:install_pip(l:ctx)
  elseif l:method ==# 'go_install'
    call s:install_go(l:ctx)
  elseif l:method ==# 'github_release'
    call s:install_github_release(l:ctx)
  else
    echoerr printf('[yac] Unknown install method: %s', l:method)
    call s:cleanup_failed(l:ctx)
  endif
endfunction

" npm install
function! s:install_npm(ctx) abort
  " Two-step: npm init -y, then npm install <packages>
  let l:init_cmd = ['npm', 'init', '-y']
  call job_start(l:init_cmd, {
    \ 'cwd': a:ctx.staging,
    \ 'exit_cb': function('s:on_npm_init_done', [a:ctx]),
    \ 'out_io': 'null',
    \ 'err_io': 'null',
    \ })
endfunction

function! s:on_npm_init_done(ctx, job, exit_code) abort
  if a:exit_code != 0
    call yac#toast('npm init failed', {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif
  let l:pkgs = split(a:ctx.install_info.package, ' ')
  let l:cmd = ['npm', 'install'] + l:pkgs
  call job_start(l:cmd, {
    \ 'cwd': a:ctx.staging,
    \ 'exit_cb': function('s:on_install_done', [a:ctx]),
    \ 'out_io': 'null',
    \ 'err_io': 'null',
    \ })
endfunction

" pip install
function! s:install_pip(ctx) abort
  let l:venv_dir = a:ctx.staging . '/venv'
  let l:cmd = ['python3', '-m', 'venv', l:venv_dir]
  call job_start(l:cmd, {
    \ 'exit_cb': function('s:on_pip_venv_done', [a:ctx]),
    \ 'out_io': 'null',
    \ 'err_io': 'null',
    \ })
endfunction

function! s:on_pip_venv_done(ctx, job, exit_code) abort
  if a:exit_code != 0
    call yac#toast('python3 venv creation failed', {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif
  let l:pip = a:ctx.staging . '/venv/bin/pip'
  let l:pkgs = split(a:ctx.install_info.package, ' ')
  let l:cmd = [l:pip, 'install'] + l:pkgs
  call job_start(l:cmd, {
    \ 'exit_cb': function('s:on_install_done', [a:ctx]),
    \ 'out_io': 'null',
    \ 'err_io': 'null',
    \ })
endfunction

" go install
function! s:install_go(ctx) abort
  let l:bin_dir = a:ctx.staging . '/bin'
  call mkdir(l:bin_dir, 'p')
  let l:cmd = ['go', 'install', a:ctx.install_info.package]
  call job_start(l:cmd, {
    \ 'env': {'GOBIN': l:bin_dir},
    \ 'exit_cb': function('s:on_install_done', [a:ctx]),
    \ 'out_io': 'null',
    \ 'err_io': 'null',
    \ })
endfunction

" github_release install — download pre-built binary from GitHub Releases
function! s:install_github_release(ctx) abort
  let l:info = a:ctx.install_info

  " Detect platform
  let l:uname_s = trim(system('uname -s'))
  let l:uname_m = trim(system('uname -m'))
  " Normalize arch: arm64 → aarch64
  if l:uname_m ==# 'arm64'
    let l:uname_m = 'aarch64'
  endif

  let l:platform_map = get(l:info, 'platform_map', {})
  let l:platform = get(l:platform_map, l:uname_s, '')
  if empty(l:platform)
    call yac#toast(printf('Unsupported platform: %s', l:uname_s), {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif

  " Build asset name from pattern
  let l:asset_pattern = get(l:info, 'asset', '')
  if empty(l:asset_pattern)
    call yac#toast('No asset pattern in install config', {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif
  let l:asset = substitute(l:asset_pattern, '{ARCH}', l:uname_m, 'g')
  let l:asset = substitute(l:asset, '{PLATFORM}', l:platform, 'g')

  " Construct download URL
  let l:repo = get(l:info, 'repo', '')
  let l:url = printf('https://github.com/%s/releases/latest/download/%s', l:repo, l:asset)

  call yac#_install_debug_log(printf('Downloading %s from %s', l:asset, l:url))

  " Download to staging
  let l:download_path = a:ctx.staging . '/' . l:asset
  let l:cmd = ['curl', '-fSL', '-o', l:download_path, l:url]
  call job_start(l:cmd, {
    \ 'exit_cb': function('s:on_github_download_done', [a:ctx, l:download_path, l:asset]),
    \ 'out_io': 'null',
    \ 'err_io': 'null',
    \ })
endfunction

function! s:on_github_download_done(ctx, download_path, asset, job, exit_code) abort
  if a:exit_code != 0
    call yac#toast(printf('Download failed: %s', a:asset), {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif

  " Extract based on file extension
  let l:bin_dir = a:ctx.staging . '/bin'
  call mkdir(l:bin_dir, 'p')

  if a:asset =~# '\.tar\.xz$' || a:asset =~# '\.tar\.gz$'
    " tar archive — extract binary to bin/
    let l:cmd = ['tar', 'xf', a:download_path, '-C', l:bin_dir, '--strip-components=0']
    call job_start(l:cmd, {
      \ 'exit_cb': function('s:on_github_extract_done', [a:ctx]),
      \ 'out_io': 'null',
      \ 'err_io': 'null',
      \ })
  elseif a:asset =~# '\.gz$'
    " Single gzipped binary
    let l:out_path = l:bin_dir . '/' . a:ctx.bin_name
    let l:cmd = printf('gunzip -c %s > %s && chmod +x %s',
      \ shellescape(a:download_path), shellescape(l:out_path), shellescape(l:out_path))
    call job_start(['/bin/sh', '-c', l:cmd], {
      \ 'exit_cb': function('s:on_github_extract_done', [a:ctx]),
      \ 'out_io': 'null',
      \ 'err_io': 'null',
      \ })
  elseif a:asset =~# '\.zip$'
    let l:cmd = ['unzip', '-o', a:download_path, '-d', l:bin_dir]
    call job_start(l:cmd, {
      \ 'exit_cb': function('s:on_github_extract_done', [a:ctx]),
      \ 'out_io': 'null',
      \ 'err_io': 'null',
      \ })
  else
    " Assume raw binary
    let l:out_path = l:bin_dir . '/' . a:ctx.bin_name
    call rename(a:download_path, l:out_path)
    call system('chmod +x ' . shellescape(l:out_path))
    call s:on_install_done(a:ctx, 0, 0)
    return
  endif
endfunction

function! s:on_github_extract_done(ctx, job, exit_code) abort
  if a:exit_code != 0
    call yac#toast(printf('Extract failed for %s', a:ctx.bin_name), {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif
  call s:on_install_done(a:ctx, a:job, 0)
endfunction

" Common install completion callback.
function! s:on_install_done(ctx, job, exit_code) abort
  if a:exit_code != 0
    call yac#toast(printf('Failed to install %s (exit %d)', a:ctx.bin_name, a:exit_code), {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif

  " Atomic promote: staging → packages
  if isdirectory(a:ctx.dest)
    call delete(a:ctx.dest, 'rf')
  endif
  call mkdir(s:packages_dir, 'p')
  if rename(a:ctx.staging, a:ctx.dest) != 0
    call yac#toast(printf('Failed to move %s to install dir', a:ctx.bin_name), {'highlight': 'ErrorMsg'})
    call s:cleanup_failed(a:ctx)
    return
  endif

  " Create bin symlink
  call mkdir(s:bin_dir, 'p')
  let l:symlink_path = s:bin_dir . '/' . a:ctx.bin_name
  let l:target = s:find_binary(a:ctx)

  if empty(l:target)
    call yac#toast(printf('Installed but binary not found: %s', a:ctx.bin_name), {'highlight': 'WarningMsg'})
    call s:finish_install(a:ctx)
    return
  endif

  " Remove existing symlink
  if filereadable(l:symlink_path) || getftype(l:symlink_path) ==# 'link'
    call delete(l:symlink_path)
  endif

  call system(printf('ln -s %s %s', shellescape(l:target), shellescape(l:symlink_path)))

  " Write metadata.json
  let l:metadata = {'installed_at': strftime('%Y-%m-%dT%H:%M:%S'), 'method': a:ctx.install_info.method, 'package': get(a:ctx.install_info, 'package', get(a:ctx.install_info, 'repo', ''))}
  call writefile([json_encode(l:metadata)], a:ctx.dest . '/metadata.json')

  call yac#toast(printf('Installed %s successfully', a:ctx.bin_name))
  call yac#_install_debug_log(printf('Installed %s: %s -> %s', a:ctx.bin_name, l:symlink_path, l:target))

  call s:finish_install(a:ctx)
endfunction

" Find the installed binary path.
function! s:find_binary(ctx) abort
  let l:method = a:ctx.install_info.method

  if l:method ==# 'npm'
    " node_modules/.bin/<bin_name>
    let l:path = a:ctx.dest . '/node_modules/.bin/' . a:ctx.bin_name
    if filereadable(l:path) | return l:path | endif
  elseif l:method ==# 'pip'
    let l:path = a:ctx.dest . '/venv/bin/' . a:ctx.bin_name
    if filereadable(l:path) | return l:path | endif
  elseif l:method ==# 'go_install' || l:method ==# 'github_release'
    let l:path = a:ctx.dest . '/bin/' . a:ctx.bin_name
    if filereadable(l:path) | return l:path | endif
  endif

  return ''
endfunction

" Reset daemon failed state and re-trigger file_open.
function! s:finish_install(ctx) abort
  if has_key(s:installing, a:ctx.language)
    unlet s:installing[a:ctx.language]
  endif

  " Notify daemon to reset spawn failure flag
  call yac#_install_request('lsp_reset_failed',
    \ {'language': a:ctx.language},
    \ function('s:on_reset_done'))
endfunction

function! s:on_reset_done(channel, response) abort
  " Re-trigger file_open for current buffer
  call yac#open_file()
endfunction

" Cleanup on failure.
function! s:cleanup_failed(ctx) abort
  if isdirectory(a:ctx.staging)
    call delete(a:ctx.staging, 'rf')
  endif
  if has_key(s:installing, a:ctx.language)
    unlet s:installing[a:ctx.language]
  endif
endfunction

" Install LSP server for [language] (command palette: LSP Install)
function! yac_install#install(...) abort
  let l:language = a:0 > 0 ? a:1 : ''

  if empty(l:language)
    " Use current buffer language
    let l:install = get(b:, 'yac_lsp_install', {})
    let l:command = get(b:, 'yac_lsp_command', '')
    if empty(l:install) || empty(l:command)
      echoerr '[yac] No LSP server configured for current buffer'
      return
    endif
    " Detect language from extension
    let l:file = expand('%:p')
    let l:language = s:detect_language(l:file)
    if empty(l:language)
      echoerr '[yac] Cannot detect language for current file'
      return
    endif
    call yac_install#run(l:language, l:install)
    return
  endif

  " Find install info from languages.json
  let l:info = s:find_language_install(l:language)
  if empty(l:info)
    echoerr printf('[yac] No install info found for language: %s', l:language)
    return
  endif
  call yac_install#run(l:language, l:info)
endfunction

" Update LSP server for [language] (command palette: LSP Update)
function! yac_install#update(...) abort
  let l:language = a:0 > 0 ? a:1 : ''

  if empty(l:language)
    let l:file = expand('%:p')
    let l:language = s:detect_language(l:file)
    if empty(l:language)
      echoerr '[yac] Cannot detect language for current file'
      return
    endif
  endif

  let l:info = s:find_language_install(l:language)
  if empty(l:info)
    echoerr printf('[yac] No install info found for language: %s', l:language)
    return
  endif

  let l:bin_name = get(l:info, 'bin_name', '')
  if empty(l:bin_name)
    let l:pkg = get(l:info, 'package', get(l:info, 'repo', ''))
    let l:bin_name = split(l:pkg, ' ')[0]
    let l:bin_name = split(l:bin_name, '/')[-1]
    let l:bin_name = split(l:bin_name, '@')[0]
  endif

  " Remove existing package and symlink
  let l:pkg_dir = s:packages_dir . '/' . l:bin_name
  let l:symlink = s:bin_dir . '/' . l:bin_name
  if isdirectory(l:pkg_dir) | call delete(l:pkg_dir, 'rf') | endif
  if filereadable(l:symlink) || getftype(l:symlink) ==# 'link' | call delete(l:symlink) | endif

  call yac_install#run(l:language, l:info)
endfunction

" Show LSP server status (command palette: LSP Status)
function! yac_install#status() abort
  echo 'YAC LSP Server Status'
  echo '====================='
  echo ''

  for [lang, lang_dir] in items(g:yac_lang_plugins)
    let l:json_path = lang_dir . '/languages.json'
    if !filereadable(l:json_path) | continue | endif
    try
      let l:config = json_decode(join(readfile(l:json_path), "\n"))
      for [name, info] in items(l:config)
        let l:lsp_server = get(info, 'lsp_server', {})
        if empty(l:lsp_server) | continue | endif

        let l:cmd = l:lsp_server.command
        let l:install = get(l:lsp_server, 'install', {})
        let l:method = get(l:install, 'method', 'system')

        " Check if available in PATH
        let l:in_path = executable(l:cmd)

        " Check managed install
        let l:managed_bin = s:bin_dir . '/' . l:cmd
        let l:managed = filereadable(l:managed_bin) || getftype(l:managed_bin) ==# 'link'

        " Read metadata
        let l:version_info = ''
        let l:bin_name = get(l:install, 'bin_name', l:cmd)
        let l:meta_path = s:packages_dir . '/' . l:bin_name . '/metadata.json'
        if filereadable(l:meta_path)
          try
            let l:meta = json_decode(join(readfile(l:meta_path), "\n"))
            let l:version_info = get(l:meta, 'installed_at', '')
          catch
          endtry
        endif

        let l:status = l:in_path ? 'PATH' : (l:managed ? 'managed' : 'not installed')
        let l:status_hl = l:in_path || l:managed ? '' : ' (!)'

        echo printf('  %s (%s): %s%s%s',
          \ name, l:cmd, l:status, l:status_hl,
          \ empty(l:version_info) ? '' : printf(' [installed: %s]', l:version_info))
      endfor
    catch
      call yac#_install_debug_log(printf('Failed to parse %s: %s', l:json_path, v:exception))
    endtry
  endfor
endfunction

" Helper: detect language from file extension using languages.json.
function! s:detect_language(file) abort
  if !exists('g:yac_lang_plugins')
    return ''
  endif
  for [lang, lang_dir] in items(g:yac_lang_plugins)
    let l:json_path = lang_dir . '/languages.json'
    if !filereadable(l:json_path) | continue | endif
    try
      let l:config = json_decode(join(readfile(l:json_path), "\n"))
      for [name, info] in items(l:config)
        for ext in get(info, 'extensions', [])
          if a:file =~# '\V' . escape(ext, '\') . '\$'
            return lang
          endif
        endfor
      endfor
    catch
      call yac#_install_debug_log(printf('Failed to parse %s: %s', l:json_path, v:exception))
    endtry
  endfor
  return ''
endfunction

" Helper: find install info for a language name.
function! s:find_language_install(language) abort
  let l:lang_dir = get(g:yac_lang_plugins, a:language, '')
  if empty(l:lang_dir) | return {} | endif

  let l:json_path = l:lang_dir . '/languages.json'
  if !filereadable(l:json_path) | return {} | endif

  try
    let l:config = json_decode(join(readfile(l:json_path), "\n"))
    for [name, info] in items(l:config)
      let l:lsp_server = get(info, 'lsp_server', {})
      return get(l:lsp_server, 'install', {})
    endfor
  catch
    call yac#_install_debug_log(printf('Failed to parse %s: %s', l:json_path, v:exception))
  endtry
  return {}
endfunction
