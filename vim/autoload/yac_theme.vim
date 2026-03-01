" yac_theme.vim — Tree-sitter highlight theme management
"
" Theme file format (JSON, stored in ~/.config/yac/themes/<name>.json):
" {
"   "name": "One Dark",
"   "groups": {
"     "YacTsFunction": {"guifg": "#61AFEF", "ctermfg": "39"},
"     "YacTsKeyword":  {"guifg": "#C678DD", "ctermfg": "170", "gui": "bold"},
"     "YacTsType":     {"link": "Type"}
"   }
" }
"
" - "link" field: `hi! link YacTsXxx <target>`
" - guifg/guibg/ctermfg/ctermbg/gui/cterm: direct highlight attrs
" - empty {}: `hi! clear YacTsXxx` (reset to NONE)
" - missing group: keep current setting

" All YacTs* highlight group names (sync with yac.vim:69-108)
let s:TS_GROUPS = [
  \ 'YacTsVariable', 'YacTsVariableParameter', 'YacTsVariableBuiltin',
  \ 'YacTsVariableMember', 'YacTsType', 'YacTsTypeBuiltin',
  \ 'YacTsConstant', 'YacTsConstantBuiltin', 'YacTsLabel',
  \ 'YacTsFunction', 'YacTsFunctionBuiltin', 'YacTsFunctionCall',
  \ 'YacTsModule', 'YacTsKeyword', 'YacTsKeywordType',
  \ 'YacTsKeywordCoroutine', 'YacTsKeywordFunction', 'YacTsKeywordOperator',
  \ 'YacTsKeywordReturn', 'YacTsKeywordConditional', 'YacTsKeywordRepeat',
  \ 'YacTsKeywordImport', 'YacTsKeywordException', 'YacTsKeywordModifier',
  \ 'YacTsOperator', 'YacTsCharacter', 'YacTsString', 'YacTsStringEscape',
  \ 'YacTsNumber', 'YacTsNumberFloat', 'YacTsBoolean', 'YacTsComment',
  \ 'YacTsCommentDocumentation', 'YacTsPunctuationBracket',
  \ 'YacTsPunctuationDelimiter', 'YacTsAttribute', 'YacTsConstructor',
  \ 'YacTsFunctionMacro', 'YacTsFunctionMethod', 'YacTsProperty',
  \ ]

" Default theme: mirrors yac.vim:69-108 hi def link definitions
let s:default_groups = {
  \ 'YacTsVariable':             {},
  \ 'YacTsVariableParameter':    {'link': 'Identifier'},
  \ 'YacTsVariableBuiltin':      {'link': 'Special'},
  \ 'YacTsVariableMember':       {'link': 'Identifier'},
  \ 'YacTsType':                 {'link': 'Type'},
  \ 'YacTsTypeBuiltin':          {'link': 'Type'},
  \ 'YacTsConstant':             {'link': 'Constant'},
  \ 'YacTsConstantBuiltin':      {'link': 'Constant'},
  \ 'YacTsLabel':                {'link': 'Label'},
  \ 'YacTsFunction':             {'link': 'Function'},
  \ 'YacTsFunctionBuiltin':      {'link': 'Special'},
  \ 'YacTsFunctionCall':         {'link': 'Function'},
  \ 'YacTsModule':               {'link': 'Include'},
  \ 'YacTsKeyword':              {'link': 'Keyword'},
  \ 'YacTsKeywordType':          {'link': 'Keyword'},
  \ 'YacTsKeywordCoroutine':     {'link': 'Keyword'},
  \ 'YacTsKeywordFunction':      {'link': 'Keyword'},
  \ 'YacTsKeywordOperator':      {'link': 'Keyword'},
  \ 'YacTsKeywordReturn':        {'link': 'Keyword'},
  \ 'YacTsKeywordConditional':   {'link': 'Conditional'},
  \ 'YacTsKeywordRepeat':        {'link': 'Repeat'},
  \ 'YacTsKeywordImport':        {'link': 'Include'},
  \ 'YacTsKeywordException':     {'link': 'Exception'},
  \ 'YacTsKeywordModifier':      {'link': 'StorageClass'},
  \ 'YacTsOperator':             {'link': 'Operator'},
  \ 'YacTsCharacter':            {'link': 'Character'},
  \ 'YacTsString':               {'link': 'String'},
  \ 'YacTsStringEscape':         {'link': 'SpecialChar'},
  \ 'YacTsNumber':               {'link': 'Number'},
  \ 'YacTsNumberFloat':          {'link': 'Float'},
  \ 'YacTsBoolean':              {'link': 'Boolean'},
  \ 'YacTsComment':              {'link': 'Comment'},
  \ 'YacTsCommentDocumentation': {'link': 'SpecialComment'},
  \ 'YacTsPunctuationBracket':   {'link': 'Delimiter'},
  \ 'YacTsPunctuationDelimiter': {'link': 'Delimiter'},
  \ 'YacTsAttribute':            {'link': 'PreProc'},
  \ 'YacTsConstructor':          {'link': 'Special'},
  \ 'YacTsFunctionMacro':        {'link': 'Macro'},
  \ 'YacTsFunctionMethod':       {'link': 'Function'},
  \ 'YacTsProperty':             {'link': 'Identifier'},
  \ }

let s:current_theme = ''

function! yac_theme#theme_dir() abort
  return expand('~/.config/yac/themes')
endfunction

" List available themes: [{'label': name, 'file': path}, ...]
function! yac_theme#list() abort
  let items = [{'label': '[default]', 'file': ''}]
  let dir = yac_theme#theme_dir()
  if !isdirectory(dir)
    return items
  endif
  for f in sort(glob(dir . '/*.json', 0, 1))
    try
      let data = json_decode(join(readfile(f), "\n"))
      let name = get(data, 'name', fnamemodify(f, ':t:r'))
    catch
      let name = fnamemodify(f, ':t:r')
    endtry
    call add(items, {'label': name, 'file': f})
  endfor
  return items
endfunction

" Apply a theme from a JSON file. Empty file = default theme.
function! yac_theme#apply_file(file) abort
  if empty(a:file)
    call yac_theme#apply_default()
    return
  endif
  try
    let data = json_decode(join(readfile(a:file), "\n"))
    let groups = get(data, 'groups', {})
    call s:apply_groups(groups)
    let s:current_theme = get(data, 'name', fnamemodify(a:file, ':t:r'))
  catch
    echohl ErrorMsg | echo 'yac: failed to load theme: ' . a:file | echohl None
  endtry
endfunction

" Restore default theme (hi def link mappings)
function! yac_theme#apply_default() abort
  call s:apply_groups(s:default_groups)
  let s:current_theme = ''
endfunction

function! s:apply_groups(groups) abort
  for group in s:TS_GROUPS
    if !has_key(a:groups, group) | continue | endif
    let spec = a:groups[group]
    " Clear any existing link first
    execute 'hi! link ' . group . ' NONE'
    if has_key(spec, 'link')
      execute 'hi! link ' . group . ' ' . spec.link
    else
      let parts = []
      for attr in ['guifg', 'guibg', 'ctermfg', 'ctermbg', 'gui', 'cterm']
        if has_key(spec, attr)
          call add(parts, attr . '=' . spec[attr])
        endif
      endfor
      if empty(parts)
        execute 'hi! clear ' . group
      else
        execute 'hi! ' . group . ' ' . join(parts, ' ')
      endif
    endif
  endfor
endfunction

" Persist current theme selection
function! yac_theme#save_selection(file) abort
  let cfg = expand('~/.config/yac/theme.txt')
  let dir = fnamemodify(cfg, ':h')
  if !isdirectory(dir) | call mkdir(dir, 'p') | endif
  call writefile([a:file], cfg)
endfunction

" Load saved theme on startup
function! yac_theme#autoload() abort
  let cfg = expand('~/.config/yac/theme.txt')
  if !filereadable(cfg) | return | endif
  let saved = get(readfile(cfg), 0, '')
  if !empty(saved) && filereadable(saved)
    call yac_theme#apply_file(saved)
  endif
endfunction

" Get saved theme file path (for preview restore)
function! yac_theme#saved_file() abort
  let cfg = expand('~/.config/yac/theme.txt')
  if !filereadable(cfg) | return '' | endif
  return get(readfile(cfg), 0, '')
endfunction

function! yac_theme#current() abort
  return s:current_theme
endfunction
