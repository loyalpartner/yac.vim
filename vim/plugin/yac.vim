" yac.vim plugin entry point

" 兼容性检查 - 需要 channel + Unix socket 支持
if !has('channel') || !has('job')
  finish
endif

" 配置选项
let g:yac_diagnostic_virtual_text = get(g:, 'yac_diagnostic_virtual_text', 1)

" 自动补全配置选项
let g:yac_auto_complete = get(g:, 'yac_auto_complete', 1)
let g:yac_auto_complete_delay = get(g:, 'yac_auto_complete_delay', 0)
let g:yac_auto_complete_min_chars = get(g:, 'yac_auto_complete_min_chars', 1)
let g:yac_auto_complete_triggers = get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])

" Tree-sitter highlights (auto-enable for supported filetypes)
let g:yac_ts_highlights = get(g:, 'yac_ts_highlights', 1)

" Semantic tokens from LSP (overlays on tree-sitter highlights)
let g:yac_semantic_tokens = get(g:, 'yac_semantic_tokens', 1)

" LSP server auto-install (0=prompt, 1=auto-install without asking)
let g:yac_auto_install_lsp = get(g:, 'yac_auto_install_lsp', 1)

" Auto bracket/quote pairing
let g:yac_auto_pairs = get(g:, 'yac_auto_pairs', 1)

" Git signs in sign column
let g:yac_git_signs = get(g:, 'yac_git_signs', 1)

" Language plugin registry: {"lang_name": "/path/to/plugin_root", ...}
" Each language plugin's plugin/yac_*.vim registers itself here.
if !exists('g:yac_lang_plugins')
  let g:yac_lang_plugins = {}
endif

" Auto-register languages bundled with yac.vim (overridable by external plugins)
let s:_builtin = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h') . '/languages'
if isdirectory(s:_builtin)
  for s:_dir in glob(s:_builtin . '/*', 0, 1)
    if isdirectory(s:_dir)
      let g:yac_lang_plugins[fnamemodify(s:_dir, ':t')] = s:_dir
    endif
  endfor
  unlet! s:_dir
endif
unlet s:_builtin

" Core commands
command! YacStart   call yac#start()
command! YacStop    call yac#stop()
command! YacRestart call yac#restart()

" Everything else via <C-p> > command palette

" <Plug> mappings — LSP navigation
nnoremap <silent> <Plug>(YacDefinition)     :call yac#goto_definition()<CR>
nnoremap <silent> <Plug>(YacDeclaration)    :call yac#goto_declaration()<CR>
nnoremap <silent> <Plug>(YacTypeDefinition) :call yac#goto_type_definition()<CR>
nnoremap <silent> <Plug>(YacImplementation) :call yac#goto_implementation()<CR>
nnoremap <silent> <Plug>(YacReferences)     :call yac#references()<CR>
nnoremap <silent> <Plug>(YacPeek)           :call yac#peek()<CR>

" <Plug> mappings — LSP editing
nnoremap <silent> <Plug>(YacRename)     :call yac#rename()<CR>
nnoremap <silent> <Plug>(YacCodeAction) :call yac#code_action()<CR>
nnoremap <silent> <Plug>(YacFormat)     :call yac#format()<CR>
xnoremap <silent> <Plug>(YacRangeFormat) :<C-u>call yac#range_format()<CR>

" <Plug> mappings — LSP info
nnoremap <silent> <Plug>(YacHover)         :call yac#hover()<CR>
nnoremap <silent> <Plug>(YacSignatureHelp) :call yac#signature_help()<CR>
nnoremap <silent> <Plug>(YacDocumentSymbols) :call yac#document_symbols()<CR>

" <Plug> mappings — LSP hierarchy
nnoremap <silent> <Plug>(YacCallHierarchyIncoming) :call yac#call_hierarchy_incoming()<CR>
nnoremap <silent> <Plug>(YacCallHierarchyOutgoing) :call yac#call_hierarchy_outgoing()<CR>
nnoremap <silent> <Plug>(YacTypeHierarchySupertypes) :call yac#type_hierarchy_supertypes()<CR>
nnoremap <silent> <Plug>(YacTypeHierarchySubtypes)   :call yac#type_hierarchy_subtypes()<CR>

" <Plug> mappings — LSP toggles
nnoremap <silent> <Plug>(YacInlayHintsToggle)    :call yac#inlay_hints_toggle()<CR>
nnoremap <silent> <Plug>(YacDiagnosticVTToggle)  :call yac#toggle_diagnostic_virtual_text()<CR>
nnoremap <silent> <Plug>(YacSemanticTokensToggle) :call yac#semantic_tokens_toggle()<CR>

" <Plug> mappings — folding
nnoremap <silent> <Plug>(YacFoldingRange) :call yac#folding_range()<CR>

" <Plug> mappings — picker
nnoremap <silent> <Plug>(YacPicker) :call yac#picker_open()<CR>
nnoremap <silent> <Plug>(YacGrep)   :call yac#picker_open({'initial': '/'})<CR>

" <Plug> mappings — alternate file (C/C++ header ↔ implementation)
nnoremap <silent> <Plug>(YacAlternate) :call yac_alternate#switch()<CR>

" <Plug> mappings — DAP debugging
nnoremap <silent> <Plug>(YacDapStart)            :call yac#dap_start()<CR>
nnoremap <silent> <Plug>(YacDapToggleBreakpoint) :call yac#dap_toggle_breakpoint()<CR>
nnoremap <silent> <Plug>(YacDapClearBreakpoints) :call yac#dap_clear_breakpoints()<CR>
nnoremap <silent> <Plug>(YacDapContinue)         :call yac#dap_continue()<CR>
nnoremap <silent> <Plug>(YacDapNext)             :call yac#dap_next()<CR>
nnoremap <silent> <Plug>(YacDapStepIn)           :call yac#dap_step_in()<CR>
nnoremap <silent> <Plug>(YacDapStepOut)          :call yac#dap_step_out()<CR>
nnoremap <silent> <Plug>(YacDapTerminate)        :call yac#dap_terminate()<CR>
nnoremap <silent> <Plug>(YacDapStackTrace)       :call yac#dap_stack_trace()<CR>
nnoremap <silent> <Plug>(YacDapVariables)        :call yac#dap_variables()<CR>
nnoremap <silent> <Plug>(YacDapRepl)             :call yac#dap_repl()<CR>
nnoremap <silent> <Plug>(YacDapAttach)           :call yac_dap#attach()<CR>

" <Plug> mappings — tree-sitter navigation
nnoremap <silent> <Plug>(YacTsNextFunction) :call yac#ts_next_function()<CR>
nnoremap <silent> <Plug>(YacTsPrevFunction) :call yac#ts_prev_function()<CR>
nnoremap <silent> <Plug>(YacTsNextStruct)   :call yac#ts_next_struct()<CR>
nnoremap <silent> <Plug>(YacTsPrevStruct)   :call yac#ts_prev_struct()<CR>

" <Plug> mappings — tree-sitter text objects
xnoremap <silent> <Plug>(YacTsFunctionOuter) :<C-u>call yac#ts_select('function.outer')<CR>
xnoremap <silent> <Plug>(YacTsFunctionInner) :<C-u>call yac#ts_select('function.inner')<CR>
xnoremap <silent> <Plug>(YacTsClassOuter)    :<C-u>call yac#ts_select('class.outer')<CR>
onoremap <silent> <Plug>(YacTsFunctionOuter) :<C-u>call yac#ts_select('function.outer')<CR>
onoremap <silent> <Plug>(YacTsFunctionInner) :<C-u>call yac#ts_select('function.inner')<CR>
onoremap <silent> <Plug>(YacTsClassOuter)    :<C-u>call yac#ts_select('class.outer')<CR>

" Default key mappings (use nmap so <Plug> triggers; user can override)
nmap <silent> gd <Plug>(YacDefinition)
nmap <silent> gD <Plug>(YacPeek)
nmap <silent> gy <Plug>(YacTypeDefinition)
nmap <silent> gi <Plug>(YacImplementation)
nmap <silent> gr <Plug>(YacReferences)
nmap <silent> K  <Plug>(YacHover)
nmap <silent> <leader>rn <Plug>(YacRename)
nmap <silent> <leader>ci <Plug>(YacCallHierarchyIncoming)
nmap <silent> <leader>co <Plug>(YacCallHierarchyOutgoing)
nmap <silent> <leader>s  <Plug>(YacDocumentSymbols)
nmap <silent> <leader>f  <Plug>(YacFoldingRange)
nmap <silent> <leader>ca <Plug>(YacCodeAction)
nmap <silent> <leader>fm <Plug>(YacFormat)
xmap <silent> <leader>fm <Plug>(YacRangeFormat)
nmap <silent> <leader>ts <Plug>(YacTypeHierarchySupertypes)
nmap <silent> <leader>tt <Plug>(YacTypeHierarchySubtypes)
nmap <silent> <leader>ih <Plug>(YacInlayHintsToggle)
nmap <silent> <leader>dt <Plug>(YacDiagnosticVTToggle)
nmap <silent> <C-p>      <Plug>(YacPicker)
nmap <silent> g/         <Plug>(YacGrep)

" DAP debugging defaults — IDE-style F-keys + leader-d prefix
nmap <silent> <F5>        <Plug>(YacDapStart)
nmap <silent> <F9>        <Plug>(YacDapToggleBreakpoint)
nmap <silent> <F10>       <Plug>(YacDapNext)
nmap <silent> <F11>       <Plug>(YacDapStepIn)
nmap <silent> <S-F11>     <Plug>(YacDapStepOut)
nmap <silent> <S-F5>      <Plug>(YacDapTerminate)
nmap <silent> <leader>db  <Plug>(YacDapToggleBreakpoint)
nmap <silent> <leader>dc  <Plug>(YacDapContinue)
nmap <silent> <leader>dn  <Plug>(YacDapNext)
nmap <silent> <leader>di  <Plug>(YacDapStepIn)
nmap <silent> <leader>do  <Plug>(YacDapStepOut)
nmap <silent> <leader>ds  <Plug>(YacDapStart)
nmap <silent> <leader>dx  <Plug>(YacDapTerminate)
nmap <silent> <leader>dv  <Plug>(YacDapVariables)
nmap <silent> <leader>dr  <Plug>(YacDapRepl)
nmap <silent> <leader>da  <Plug>(YacDapAttach)

" Tree-sitter navigation defaults
nmap <silent> ]f <Plug>(YacTsNextFunction)
nmap <silent> [f <Plug>(YacTsPrevFunction)
nmap <silent> ]s <Plug>(YacTsNextStruct)
nmap <silent> [s <Plug>(YacTsPrevStruct)

" Tree-sitter text object defaults
xmap <silent> af <Plug>(YacTsFunctionOuter)
xmap <silent> if <Plug>(YacTsFunctionInner)
xmap <silent> ac <Plug>(YacTsClassOuter)
omap <silent> af <Plug>(YacTsFunctionOuter)
omap <silent> if <Plug>(YacTsFunctionInner)
omap <silent> ac <Plug>(YacTsClassOuter)

" Build extension-to-plugin mapping from g:yac_lang_plugins.
" Each plugin has a languages.json with {"lang": {"extensions": [".ext", ...], ...}}.
" Returns a dict: {".ext": {"dir": "lang_dir", "lsp": bool}, ...}
function! s:build_ext_map() abort
  let l:ext_map = {}
  for [lang, lang_dir] in items(g:yac_lang_plugins)
    let l:json_path = lang_dir . '/languages.json'
    if !filereadable(l:json_path) | continue | endif
    try
      let l:config = json_decode(join(readfile(l:json_path), "\n"))
      for [name, info] in items(l:config)
        let l:has_lsp = get(info, 'lsp', 1)
        let l:lsp_server = get(info, 'lsp_server', {})
        let l:install = get(l:lsp_server, 'install', {})
        let l:lsp_command = get(l:lsp_server, 'command', '')
        for ext in get(info, 'extensions', [])
          let l:ext_map[ext] = {'dir': lang_dir, 'lsp': l:has_lsp,
              \ 'install': l:install, 'lsp_command': l:lsp_command}
        endfor
      endfor
    catch
      echohl WarningMsg | echom 'yac: failed to parse ' . l:json_path . ': ' . v:exception | echohl None
    endtry
  endfor
  return l:ext_map
endfunction

" Check if the current file matches a language plugin and ensure it's loaded.
function! s:yac_check_language() abort
  let l:file = expand('%:p')
  if empty(l:file) | return | endif
  let b:yac_lsp_supported = 0
  if !exists('s:yac_ext_map') | let s:yac_ext_map = s:build_ext_map() | endif
  for [ext, info] in items(s:yac_ext_map)
    if l:file =~# '\V' . escape(ext, '\') . '\$'
      if info.lsp
        let b:yac_lsp_supported = 1
      endif
      let b:yac_lang_dir = info.dir
      let b:yac_lsp_install = info.install
      let b:yac_lsp_command = info.lsp_command
      call yac#ensure_language(info.dir)
      return
    endif
  endfor
endfunction

" Guard: skip autocmds while picker preview is loading a buffer.
function! s:not_preview_loading() abort
  return !get(g:, 'yac_preview_loading', 0)
endfunction

" 简单的文件初始化和生命周期管理
" Use * pattern and check dynamically against registered language plugins
if get(g:, 'yac_auto_start', 1)
  augroup yac_auto
    autocmd!
    autocmd BufReadPost,BufNewFile * if s:not_preview_loading() | call s:yac_check_language() | call yac_remote#enhanced_lsp_start() | endif
    autocmd BufWritePre * if s:not_preview_loading() | call yac#will_save(1) | endif
    autocmd BufWritePost * if s:not_preview_loading() | call yac#did_save() | endif
    autocmd TextChanged,TextChangedI * if s:not_preview_loading() | call yac#did_change() | endif
    autocmd TextChanged * if s:not_preview_loading() | call yac#inlay_hints_on_text_changed() | endif
    autocmd BufUnload * if s:not_preview_loading() | call yac#did_close(expand('<afile>:p')) | endif
    autocmd TextChangedI * if s:not_preview_loading() | call yac#auto_complete_trigger() | call yac#signature_help_trigger() | endif
    autocmd InsertLeave * if s:not_preview_loading() | call yac#close_completion() | call yac#close_signature() | call yac#inlay_hints_on_insert_leave() | endif
    autocmd InsertEnter * if s:not_preview_loading() | call yac#inlay_hints_on_insert_enter() | endif
    autocmd CursorMoved * if s:not_preview_loading() | call yac#document_highlight_debounce() | endif
    autocmd CursorMovedI,InsertEnter * if s:not_preview_loading() | call yac#clear_document_highlights() | endif
    autocmd VimLeave * call yac#stop()
  augroup END
endif

if get(g:, 'yac_auto_start', 1)
  augroup yac_folds
    autocmd!
    autocmd CursorHold * if s:not_preview_loading() && exists('b:yac_fold_start_lines') | call yac#update_fold_signs() | endif
  augroup END
endif

" Git signs — diff markers in sign column
if get(g:, 'yac_git_signs', 1)
  call yac_gitsigns#define_signs()
  augroup yac_gitsigns
    autocmd!
    autocmd BufReadPost,BufWritePost * call yac_gitsigns#update_debounce()
  augroup END
endif

" Auto-pairs — bracket/quote auto-closing
augroup yac_autopairs
  autocmd!
  autocmd BufReadPost,BufNewFile * call yac_autopairs#setup()
augroup END

" Tree-sitter highlights autocommands
" Use * pattern — handlers check per-buffer enablement
augroup yac_ts_highlights
  autocmd!
  autocmd CursorMoved,CursorMovedI,BufEnter * if s:not_preview_loading() | call yac#ts_highlights_debounce() | endif
  autocmd WinScrolled * if s:not_preview_loading() | call yac#ts_highlights_debounce() | endif
  autocmd TextChanged,TextChangedI * if s:not_preview_loading() | call yac#ts_highlights_invalidate() | endif
  autocmd InsertLeave * if s:not_preview_loading() | call yac#ts_highlights_invalidate() | endif
  autocmd BufReadPost * if s:not_preview_loading() | call yac#ts_highlights_invalidate() | endif
  autocmd BufLeave * if s:not_preview_loading() | call yac#ts_highlights_detach() | endif
augroup END

" Semantic tokens — request after save and on buffer enter (debounced)
if get(g:, 'yac_semantic_tokens', 1)
  augroup yac_semantic_tokens
    autocmd!
    autocmd BufWritePost * if s:not_preview_loading() | call yac#semantic_tokens_debounce() | endif
    autocmd InsertLeave * if s:not_preview_loading() | call yac#semantic_tokens_debounce() | endif
  augroup END
endif

" Load saved theme on startup; reapply after colorscheme changes
call yac_theme#autoload()
augroup yac_theme
  autocmd!
  autocmd ColorScheme * call yac_theme#autoload()
augroup END

" Auto-reload files modified externally (e.g. by other Vim clients sharing the same daemon)
" Disable with: let g:yac_autoread = 0
if get(g:, 'yac_autoread', 1)
  set autoread
  augroup yac_autoread
    autocmd!
    autocmd FocusGained,BufEnter * silent! checktime
    autocmd CursorHold * silent! checktime
  augroup END
endif

" Enable Copilot by default (set g:yac_copilot_auto = 0 to disable)
if get(g:, 'yac_copilot_auto', 1)
  call yac_copilot#enable()
endif
