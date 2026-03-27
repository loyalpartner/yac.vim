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

let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

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
  \ 'YacTsFunctionMacro', 'YacTsFunctionMethod', 'YacTsProperty', 'YacTsPreproc',
  \ 'YacTsMarkupHeading', 'YacTsMarkupHeadingMarker',
  \ 'YacTsMarkupRawBlock', 'YacTsMarkupRawInline',
  \ 'YacTsMarkupLink', 'YacTsMarkupLinkUrl', 'YacTsMarkupLinkLabel',
  \ 'YacTsMarkupListMarker', 'YacTsMarkupListChecked',
  \ 'YacTsMarkupListUnchecked', 'YacTsMarkupQuote',
  \ 'YacTsMarkupItalic', 'YacTsMarkupBold', 'YacTsMarkupStrikethrough',
  \ 'YacPickerBorder', 'YacPickerInput', 'YacPickerNormal',
  \ 'YacPickerSelected', 'YacPickerHeader', 'YacPickerCursor',
  \ 'YacPickerPrefix', 'YacPickerMatch', 'YacPickerDetail', 'YacPickerFooter',
  \ 'YacDapBreakpoint', 'YacDapBreakpointVerified',
  \ 'YacDapCurrentLine', 'YacDapCurrentLineNr',
  \ 'YacDapBorder', 'YacDapNormal', 'YacDapTitle',
  \ 'YacDapVarName', 'YacDapVarValue', 'YacDapVarType',
  \ 'YacDapReplPrompt', 'YacDapReplOutput', 'YacDapReplError',
  \ 'YacDapStatusRunning', 'YacDapStatusStopped',
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
  \ 'YacTsPreproc':              {'link': 'PreProc'},
  \ 'YacTsMarkupHeading':        {'link': 'YacTsProperty'},
  \ 'YacTsMarkupHeadingMarker':  {'link': 'YacTsProperty'},
  \ 'YacTsMarkupRawBlock':       {'link': 'YacTsString'},
  \ 'YacTsMarkupRawInline':      {'link': 'YacTsString'},
  \ 'YacTsMarkupLink':           {'link': 'YacTsFunction'},
  \ 'YacTsMarkupLinkUrl':        {'link': 'YacTsType'},
  \ 'YacTsMarkupLinkLabel':      {'link': 'YacTsFunction'},
  \ 'YacTsMarkupListMarker':     {'link': 'YacTsProperty'},
  \ 'YacTsMarkupListChecked':    {'link': 'YacTsString'},
  \ 'YacTsMarkupListUnchecked':  {'link': 'YacTsComment'},
  \ 'YacTsMarkupQuote':          {'link': 'YacTsComment'},
  \ 'YacTsMarkupItalic':         {'link': 'YacTsLabel'},
  \ 'YacTsMarkupBold':           {'link': 'YacTsConstantBuiltin'},
  \ 'YacTsMarkupStrikethrough':  {'link': 'YacTsComment'},
  \ 'YacPickerBorder':           {'guifg': '#73ade9', 'guibg': '#21252b', 'ctermfg': '75', 'ctermbg': '235'},
  \ 'YacPickerInput':            {'guifg': '#dce0e5', 'guibg': '#21252b', 'ctermfg': '253', 'ctermbg': '235'},
  \ 'YacPickerNormal':           {'guifg': '#acb2be', 'guibg': '#21252b', 'ctermfg': '145', 'ctermbg': '235'},
  \ 'YacPickerSelected':         {'guifg': '#dce0e5', 'guibg': '#2c313a', 'ctermfg': '253', 'ctermbg': '236'},
  \ 'YacPickerHeader':           {'guifg': '#73ade9', 'ctermfg': '75', 'gui': 'bold'},
  \ 'YacPickerCursor':           {'gui': 'reverse', 'cterm': 'reverse'},
  \ 'YacPickerPrefix':           {'guifg': '#73ade9', 'ctermfg': '75', 'gui': 'bold'},
  \ 'YacPickerMatch':            {'guifg': '#b477cf', 'ctermfg': '176', 'gui': 'bold'},
  \ 'YacPickerDetail':           {'guifg': '#5d636f', 'ctermfg': '59'},
  \ 'YacPickerFooter':           {'guifg': '#5d636f', 'guibg': '#21252b', 'ctermfg': '59', 'ctermbg': '235'},
  \ 'YacDapBreakpoint':          {'link': 'ErrorMsg'},
  \ 'YacDapBreakpointVerified':  {'link': 'DiagnosticOk'},
  \ 'YacDapCurrentLine':         {'link': 'DiffAdd'},
  \ 'YacDapCurrentLineNr':       {'link': 'CursorLineNr'},
  \ 'YacDapBorder':              {'link': 'Comment'},
  \ 'YacDapNormal':              {'link': 'Normal'},
  \ 'YacDapTitle':               {'link': 'Title'},
  \ 'YacDapVarName':             {'link': 'Identifier'},
  \ 'YacDapVarValue':            {'link': 'String'},
  \ 'YacDapVarType':             {'link': 'Type'},
  \ 'YacDapReplPrompt':          {'link': 'Function'},
  \ 'YacDapReplOutput':          {'link': 'Normal'},
  \ 'YacDapReplError':           {'link': 'ErrorMsg'},
  \ 'YacDapStatusRunning':       {'link': 'DiagnosticOk'},
  \ 'YacDapStatusStopped':       {'link': 'DiagnosticWarn'},
  \ }

let s:current_theme = ''

function! yac_theme#theme_dir() abort
  return expand('~/.config/yac/themes')
endfunction

function! s:collect_themes(dir, items) abort
  if !isdirectory(a:dir) | return | endif
  for f in sort(glob(a:dir . '/*.json', 0, 1))
    try
      let data = json_decode(join(readfile(f), "\n"))
      let name = get(data, 'name', fnamemodify(f, ':t:r'))
    catch
      let name = fnamemodify(f, ':t:r')
    endtry
    call add(a:items, {'label': name, 'file': f})
  endfor
endfunction

" List available themes: [{'label': name, 'file': path}, ...]
function! yac_theme#list() abort
  let items = [{'label': '[default]', 'file': ''}]
  call s:collect_themes(s:plugin_root . '/themes', items)
  call s:collect_themes(yac_theme#theme_dir(), items)
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

    " Apply Vim colorscheme if specified (before groups, so yac groups override)
    " Guard against recursion: ColorScheme autocmd calls autoload() → apply_file()
    let cs = get(data, 'colorscheme', '')
    if !empty(cs) && cs !=# get(g:, 'colors_name', '') && !get(s:, 'applying_cs', 0)
      let s:applying_cs = 1
      try
        execute 'colorscheme ' . cs
      catch /E185/
        " Colorscheme not installed — skip silently
      finally
        let s:applying_cs = 0
      endtry
    endif

    let groups = get(data, 'groups', {})
    call s:apply_groups(groups)
    call s:apply_vim_syntax_links()
    let s:current_theme = get(data, 'name', fnamemodify(a:file, ':t:r'))
  catch
    echohl ErrorMsg | echo 'yac: failed to load theme: ' . a:file | echohl None
  endtry
endfunction

" Auto-derive Vim syntax highlights from YacTs* groups.
" This makes the yac theme influence Vim's built-in syntax highlighting
" so the entire editor matches the chosen theme.
function! s:apply_vim_syntax_links() abort
  let map = [
    \ ['Comment',       'YacTsComment'],
    \ ['String',        'YacTsString'],
    \ ['Character',     'YacTsCharacter'],
    \ ['Number',        'YacTsNumber'],
    \ ['Float',         'YacTsNumberFloat'],
    \ ['Boolean',       'YacTsBoolean'],
    \ ['Function',      'YacTsFunction'],
    \ ['Identifier',    'YacTsVariable'],
    \ ['Statement',     'YacTsKeyword'],
    \ ['Keyword',       'YacTsKeyword'],
    \ ['Conditional',   'YacTsKeywordConditional'],
    \ ['Repeat',        'YacTsKeywordRepeat'],
    \ ['Exception',     'YacTsKeywordException'],
    \ ['Operator',      'YacTsOperator'],
    \ ['Type',          'YacTsType'],
    \ ['StorageClass',  'YacTsKeywordModifier'],
    \ ['Constant',      'YacTsConstant'],
    \ ['PreProc',       'YacTsPreproc'],
    \ ['Include',       'YacTsKeywordImport'],
    \ ['Label',         'YacTsLabel'],
    \ ['Special',       'YacTsConstantBuiltin'],
    \ ['SpecialChar',   'YacTsStringEscape'],
    \ ['Macro',         'YacTsFunctionMacro'],
    \ ['Tag',           'YacTsAttribute'],
    \ ['Delimiter',     'YacTsPunctuationDelimiter'],
    \ ['Title',         'YacTsMarkupHeading'],
    \ ]
  for [vim_group, yac_group] in map
    execute 'hi! link ' . vim_group . ' ' . yac_group
  endfor
endfunction

" Restore default theme (hi def link mappings)
function! yac_theme#apply_default() abort
  call s:apply_groups(s:default_groups)
  call s:apply_vim_syntax_links()
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

