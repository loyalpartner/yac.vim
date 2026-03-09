" yac_config.vim — Project-level configuration (.yac.json)

" Known config keys that map to buffer-local overrides
let s:known_keys = ['auto_complete', 'ts_highlights', 'diagnostic_virtual_text',
      \ 'doc_highlight', 'auto_pairs', 'git_signs', 'copilot_auto']

" Load .yac.json from the given directory. Returns a dict or {} on failure.
function! yac_config#load(dir) abort
  let l:path = a:dir . '/.yac.json'
  if !filereadable(l:path)
    return {}
  endif
  try
    let l:content = join(readfile(l:path), "\n")
    let l:config = json_decode(l:content)
    if type(l:config) != v:t_dict
      return {}
    endif
    return l:config
  catch
    return {}
  endtry
endfunction

" Apply config overrides as buffer-local variables.
" Only known keys are applied; unknown keys are silently ignored.
function! yac_config#apply(config) abort
  if empty(a:config)
    return
  endif
  for l:key in s:known_keys
    if has_key(a:config, l:key)
      let b:yac_{l:key} = a:config[l:key]
    endif
  endfor

  " Special: theme is global, not buffer-local
  if has_key(a:config, 'theme')
    call yac_config#apply_theme(a:config.theme)
  endif
endfunction

" Apply a theme by name (looks up in built-in and user themes)
function! yac_config#apply_theme(name) abort
  " Already applied?
  if get(g:, 'yac_project_theme', '') ==# a:name
    return
  endif
  let g:yac_project_theme = a:name
  " Try to load via yac_theme if available
  try
    call yac_theme#apply_by_name(a:name)
  catch
  endtry
endfunction

" Auto-detect project root and load .yac.json for the current buffer.
function! yac_config#auto_load() abort
  let l:file = expand('%:p')
  if empty(l:file)
    return
  endif

  " Walk up to find .yac.json
  let l:dir = fnamemodify(l:file, ':h')
  while l:dir !=# '/' && l:dir !=# ''
    if filereadable(l:dir . '/.yac.json')
      let l:config = yac_config#load(l:dir)
      call yac_config#apply(l:config)
      return
    endif
    let l:dir = fnamemodify(l:dir, ':h')
  endwhile
endfunction
