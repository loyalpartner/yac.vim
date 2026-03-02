" yac.vim plugin entry point

" 兼容性检查 - 需要 channel + Unix socket 支持
if !has('channel') || !has('job')
  finish
endif

" 配置选项
let g:yac_diagnostic_virtual_text = get(g:, 'yac_diagnostic_virtual_text', 1)

" 自动补全配置选项
let g:yac_auto_complete = get(g:, 'yac_auto_complete', 1)
let g:yac_auto_complete_delay = get(g:, 'yac_auto_complete_delay', 300)
let g:yac_auto_complete_min_chars = get(g:, 'yac_auto_complete_min_chars', 2)
let g:yac_auto_complete_triggers = get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])

" Tree-sitter highlights (auto-enable for supported filetypes)
let g:yac_ts_highlights = get(g:, 'yac_ts_highlights', 1)

" Language plugin registry: {"lang_name": "/path/to/plugin_root", ...}
" Each language plugin's plugin/yac_*.vim registers itself here.
if !exists('g:yac_lang_plugins')
  let g:yac_lang_plugins = {}
endif

" 用户命令
command! YacStart          call yac#start()
command! YacStop           call yac#stop()
command! YacDefinition     call yac#goto_definition()
command! YacDeclaration    call yac#goto_declaration()
command! YacTypeDefinition call yac#goto_type_definition()
command! YacImplementation call yac#goto_implementation()
command! YacHover          call yac#hover()
command! YacComplete       call yac#complete()
command! YacReferences     call yac#references()
command! YacInlayHints       call yac#inlay_hints()
command! YacClearInlayHints  call yac#clear_inlay_hints()
command! YacInlayHintsToggle call yac#inlay_hints_toggle()
command! -nargs=? YacRename call yac#rename(<args>)
command! YacCallHierarchyIncoming call yac#call_hierarchy_incoming()
command! YacCallHierarchyOutgoing call yac#call_hierarchy_outgoing()
command! YacDocumentSymbols call yac#document_symbols()
command! YacFoldingRange   call yac#folding_range()
command! YacCodeAction    call yac#code_action()
command! -nargs=+ YacExecuteCommand call yac#execute_command(<f-args>)
command! YacFormat          call yac#format()
command! -range YacRangeFormat call yac#range_format()
command! YacSignatureHelp   call yac#signature_help()
command! YacTypeHierarchySupertypes call yac#type_hierarchy_supertypes()
command! YacTypeHierarchySubtypes call yac#type_hierarchy_subtypes()
command! -nargs=? YacWillSaveWaitUntil call yac#will_save_wait_until(<args>)
command! YacOpenLog        call yac#open_log()
command! YacToggleDiagnosticVirtualText call yac#toggle_diagnostic_virtual_text()
command! YacClearDiagnosticVirtualText call yac#clear_diagnostic_virtual_text()
command! YacDebugToggle    call yac#debug_toggle()
command! YacDebugStatus    call yac#debug_status()
command! YacConnections    call yac#connections()
command! YacCleanupConnections call yac#cleanup_connections()
command! YacDaemonStop     call yac#daemon_stop()
command! YacPicker      call yac#picker_open()
command! YacGrep        call yac#picker_open({'initial': '>'})
command! YacTsSymbols             call yac#ts_symbols()
command! YacTsHighlightsEnable    call yac#ts_highlights_enable()
command! YacTsHighlightsDisable   call yac#ts_highlights_disable()
command! YacTsHighlightsToggle    call yac#ts_highlights_toggle()
command! YacThemePicker           call yac#picker_open({'initial': '%'})
command! YacThemeDefault          call yac_theme#apply_default() | call yac_theme#save_selection('')
command! -nargs=1 -complete=file YacThemeLoad call yac_theme#apply_file(<q-args>) | call yac_theme#save_selection(<q-args>)

" 默认快捷键
nnoremap <silent> gd :YacDefinition<CR>
nnoremap <silent> gD :YacDeclaration<CR>
nnoremap <silent> gy :YacTypeDefinition<CR>
nnoremap <silent> gi :YacImplementation<CR>
nnoremap <silent> gr :YacReferences<CR>
nnoremap <silent> K  :YacHover<CR>
nnoremap <silent> <leader>rn :YacRename<CR>
nnoremap <silent> <leader>ci :YacCallHierarchyIncoming<CR>
nnoremap <silent> <leader>co :YacCallHierarchyOutgoing<CR>
nnoremap <silent> <leader>s :YacDocumentSymbols<CR>
nnoremap <silent> <leader>f :YacFoldingRange<CR>
nnoremap <silent> <leader>ca :YacCodeAction<CR>
nnoremap <silent> <leader>fm :YacFormat<CR>
xnoremap <silent> <leader>fm :YacRangeFormat<CR>
nnoremap <silent> <leader>ts :YacTypeHierarchySupertypes<CR>
nnoremap <silent> <leader>tt :YacTypeHierarchySubtypes<CR>
nnoremap <silent> <leader>ih :YacInlayHintsToggle<CR>
nnoremap <silent> <leader>dt :YacToggleDiagnosticVirtualText<CR>
nnoremap <silent> <C-p> :YacPicker<CR>
nnoremap <silent> g/ :YacGrep<CR>

" Tree-sitter navigation
nnoremap <silent> ]f :call yac#ts_next_function()<CR>
nnoremap <silent> [f :call yac#ts_prev_function()<CR>
nnoremap <silent> ]s :call yac#ts_next_struct()<CR>
nnoremap <silent> [s :call yac#ts_prev_struct()<CR>

" Tree-sitter text objects
xnoremap <silent> af :<C-u>call yac#ts_select('function.outer')<CR>
xnoremap <silent> if :<C-u>call yac#ts_select('function.inner')<CR>
xnoremap <silent> ac :<C-u>call yac#ts_select('class.outer')<CR>
onoremap <silent> af :<C-u>call yac#ts_select('function.outer')<CR>
onoremap <silent> if :<C-u>call yac#ts_select('function.inner')<CR>
onoremap <silent> ac :<C-u>call yac#ts_select('class.outer')<CR>

" Build extension-to-plugin mapping from g:yac_lang_plugins.
" Each plugin has a languages.json with {"lang": {"extensions": [".ext", ...], ...}}.
" Returns a dict: {".ext": "lang_dir", ...}
function! s:build_ext_map() abort
  let l:ext_map = {}
  for [lang, lang_dir] in items(g:yac_lang_plugins)
    let l:json_path = lang_dir . '/languages.json'
    if !filereadable(l:json_path) | continue | endif
    try
      let l:config = json_decode(join(readfile(l:json_path), "\n"))
      for [name, info] in items(l:config)
        for ext in get(info, 'extensions', [])
          let l:ext_map[ext] = lang_dir
        endfor
      endfor
    catch
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
  for [ext, lang_dir] in items(s:yac_ext_map)
    if l:file =~# '\V' . escape(ext, '\') . '\$'
      let b:yac_lsp_supported = 1
      call yac#ensure_language(lang_dir)
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
    autocmd VimLeave * call yac#daemon_stop()
  augroup END
endif

" Tree-sitter highlights autocommands
" Use * pattern — handlers check per-buffer enablement
augroup yac_ts_highlights
  autocmd!
  autocmd CursorMoved,CursorMovedI,BufEnter * if s:not_preview_loading() | call yac#ts_highlights_debounce() | endif
  autocmd WinScrolled * if s:not_preview_loading() | call yac#ts_highlights_debounce() | endif
  autocmd TextChanged,TextChangedI * if s:not_preview_loading() | call yac#ts_highlights_invalidate() | endif
  autocmd InsertLeave * if s:not_preview_loading() | call yac#ts_highlights_invalidate() | endif
  autocmd BufLeave * if s:not_preview_loading() | call yac#ts_highlights_detach() | endif
augroup END

" Load saved theme on startup; reapply after colorscheme changes
call yac_theme#autoload()
augroup yac_theme
  autocmd!
  autocmd ColorScheme * call yac_theme#autoload()
augroup END
