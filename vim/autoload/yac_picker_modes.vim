" yac_picker_modes.vim — query/accept/format implementations + mode registration
"
" Cross-module deps:
"   yac_picker#register_mode()    — register a mode spec
"   yac_picker#_close_popups()    — close popups without theme restore
"   yac_picker#open()             — re-open picker
"   yac_picker_mru#query()        — MRU query function
"   yac_theme#*                   — theme functions

" ============================================================================
" Theme mode
" ============================================================================

function! s:query_themes(query) abort
  let p = yac_picker#_get_state()
  if p.saved_theme_file is v:null
    let p.saved_theme_file = yac_theme#saved_file()
  endif
  let all = yac_theme#list()
  if empty(a:query)
    return all
  endif
  let pat = tolower(a:query)
  return filter(all, 'stridx(tolower(get(v:val, "label", "")), pat) >= 0')
endfunction

function! s:accept_theme(item) abort
  call yac_theme#apply_file(get(a:item, 'file', ''))
  call yac_theme#save_selection(get(a:item, 'file', ''))
  call yac_picker#_close_popups()
endfunction

" ============================================================================
" Buffer search mode
" ============================================================================

function! s:query_buffer(query) abort
  let p = yac_picker#_get_state()
  if empty(a:query) | return [] | endif
  let bufnr = bufnr(p.orig_file)
  if bufnr == -1 | return [] | endif
  let blines = getbufline(bufnr, 1, '$')
  let items = []
  let pat = tolower(a:query)
  for i in range(len(blines))
    if stridx(tolower(blines[i]), pat) >= 0
      call add(items, {
        \ 'label': blines[i],
        \ 'file': p.orig_file,
        \ 'line': i,
        \ 'column': stridx(tolower(blines[i]), pat),
        \ })
      if len(items) >= 200 | break | endif
    endif
  endfor
  return items
endfunction

" ============================================================================
" Help mode
" ============================================================================

function! s:query_help(query) abort
  let items = []
  for [prefix, spec] in items(yac_picker#get_modes())
    let display = empty(prefix) ? '(default)' : prefix
    let entry = {'label': display . '  ' . spec.label, 'prefix': prefix}
    if empty(a:query) || stridx(tolower(entry.label), tolower(a:query)) >= 0
      call add(items, entry)
    endif
  endfor
  " Sort: non-empty prefixes first (alphabetical), then default
  call sort(items, {a, b -> (empty(a.prefix) ? 'z' : a.prefix) < (empty(b.prefix) ? 'z' : b.prefix) ? -1 : 1})
  return items
endfunction

function! s:accept_help(item) abort
  let prefix = get(a:item, 'prefix', '')
  call yac_picker#_close_popups()
  " Re-open picker with selected prefix
  call yac_picker#open({'initial': prefix})
endfunction

" ============================================================================
" Commands mode
" ============================================================================

function! s:query_commands(query) abort
  let items = []
  " Yac built-in commands first
  for entry in s:yac_commands
    if empty(a:query) || stridx(tolower(entry.label), tolower(a:query)) >= 0
      call add(items, {'label': entry.label, 'cmd': entry.cmd, 'is_yac': 1})
    endif
  endfor
  " Vim commands
  if !empty(a:query)
    for cmd in getcompletion(a:query, 'command')
      call add(items, {'label': cmd, 'cmd': cmd, 'is_yac': 0})
      if len(items) >= 50 | break | endif
    endfor
  endif
  return items
endfunction

function! s:accept_command(item) abort
  let cmd = get(a:item, 'cmd', '')
  call yac_picker#_close_popups()
  if !empty(cmd)
    execute cmd
  endif
endfunction

" ============================================================================
" Public API
" ============================================================================

" Called at yac_picker.vim script load time to trigger this module's load
" (and therefore all the yac_picker#register_mode() calls at the bottom).
function! yac_picker_modes#_init() abort
endfunction

function! yac_picker_modes#get_commands() abort
  return s:yac_commands
endfunction

" ============================================================================
" Yac commands list
" ============================================================================

let s:yac_commands = [
  \ {'label': 'Definition', 'cmd': 'call yac#goto_definition()'},
  \ {'label': 'Declaration', 'cmd': 'call yac#goto_declaration()'},
  \ {'label': 'Type Definition', 'cmd': 'call yac#goto_type_definition()'},
  \ {'label': 'Implementation', 'cmd': 'call yac#goto_implementation()'},
  \ {'label': 'References', 'cmd': 'call yac#references()'},
  \ {'label': 'Peek Definition', 'cmd': 'call yac#peek()'},
  \ {'label': 'Rename', 'cmd': 'call yac#rename()'},
  \ {'label': 'Code Action', 'cmd': 'call yac#code_action()'},
  \ {'label': 'Format', 'cmd': 'call yac#format()'},
  \ {'label': 'Range Format', 'cmd': 'call yac#range_format()'},
  \ {'label': 'Hover', 'cmd': 'call yac#hover()'},
  \ {'label': 'Document Symbols', 'cmd': 'call yac#document_symbols()'},
  \ {'label': 'Signature Help', 'cmd': 'call yac#signature_help()'},
  \ {'label': 'Inlay Hints Toggle', 'cmd': 'call yac#inlay_hints_toggle()'},
  \ {'label': 'Semantic Tokens', 'cmd': 'call yac#semantic_tokens()'},
  \ {'label': 'Semantic Tokens Toggle', 'cmd': 'call yac#semantic_tokens_toggle()'},
  \ {'label': 'Folding Range', 'cmd': 'call yac#folding_range()'},
  \ {'label': 'Call Hierarchy Incoming', 'cmd': 'call yac#call_hierarchy_incoming()'},
  \ {'label': 'Call Hierarchy Outgoing', 'cmd': 'call yac#call_hierarchy_outgoing()'},
  \ {'label': 'Type Hierarchy Supertypes', 'cmd': 'call yac#type_hierarchy_supertypes()'},
  \ {'label': 'Type Hierarchy Subtypes', 'cmd': 'call yac#type_hierarchy_subtypes()'},
  \ {'label': 'Diagnostic Virtual Text Toggle', 'cmd': 'call yac#toggle_diagnostic_virtual_text()'},
  \ {'label': 'Tree-sitter Symbols', 'cmd': 'call yac#ts_symbols()'},
  \ {'label': 'Tree-sitter Highlights Toggle', 'cmd': 'call yac#ts_highlights_toggle()'},
  \ {'label': 'File Picker', 'cmd': 'call yac#picker_open()'},
  \ {'label': 'Grep', 'cmd': "call yac#picker_open({'initial': '/'})"},
  \ {'label': 'Theme Picker', 'cmd': "call yac#picker_open({'initial': '%'})"},
  \ {'label': 'Theme Default', 'cmd': "call yac_theme#apply_default() | call yac_theme#save_selection('')"},
  \ {'label': 'Copilot Sign In', 'cmd': 'call yac_copilot#sign_in()'},
  \ {'label': 'Copilot Sign Out', 'cmd': 'call yac_copilot#sign_out()'},
  \ {'label': 'Copilot Status', 'cmd': 'call yac_copilot#status()'},
  \ {'label': 'Copilot Enable', 'cmd': 'call yac_copilot#enable()'},
  \ {'label': 'Copilot Disable', 'cmd': 'call yac_copilot#disable()'},
  \ {'label': 'LSP Install', 'cmd': 'call yac_install#install()'},
  \ {'label': 'LSP Update', 'cmd': 'call yac_install#update()'},
  \ {'label': 'LSP Status', 'cmd': 'call yac_install#status()'},
  \ {'label': 'Restart', 'cmd': 'YacRestart'},
  \ {'label': 'Stop Daemon', 'cmd': 'YacStop'},
  \ {'label': 'Status', 'cmd': 'call yac#status()'},
  \ {'label': 'Open Log', 'cmd': 'call yac#open_log()'},
  \ {'label': 'Connections', 'cmd': 'call yac#connections()'},
  \ {'label': 'Debug Toggle', 'cmd': 'call yac#debug_toggle()'},
  \ {'label': 'Debug Status', 'cmd': 'call yac#debug_status()'},
  \ {'label': 'Alternate File', 'cmd': 'call yac_alternate#switch()'},
  \ {'label': 'DAP: Start', 'cmd': 'call yac_dap#start()'},
  \ {'label': 'DAP: Toggle Breakpoint', 'cmd': 'call yac_dap#toggle_breakpoint()'},
  \ {'label': 'DAP: Clear Breakpoints', 'cmd': 'call yac_dap#clear_breakpoints()'},
  \ {'label': 'DAP: Continue', 'cmd': 'call yac_dap#continue()'},
  \ {'label': 'DAP: Step Over', 'cmd': 'call yac_dap#next()'},
  \ {'label': 'DAP: Step In', 'cmd': 'call yac_dap#step_in()'},
  \ {'label': 'DAP: Step Out', 'cmd': 'call yac_dap#step_out()'},
  \ {'label': 'DAP: Terminate', 'cmd': 'call yac_dap#terminate()'},
  \ {'label': 'DAP: REPL', 'cmd': 'call yac_dap#repl()'},
  \ {'label': 'DAP: Toggle Mode', 'cmd': 'call yac_dap#toggle_mode()'},
  \ {'label': 'DAP: Select Frame', 'cmd': 'call yac_dap#select_frame()'},
  \ {'label': 'DAP: Threads', 'cmd': 'call yac_dap#threads()'},
  \ {'label': 'DAP: Conditional Breakpoint', 'cmd': 'call yac_dap#set_conditional_breakpoint()'},
  \ {'label': 'DAP: Log Point', 'cmd': 'call yac_dap#set_log_point()'},
  \ {'label': 'DAP: Exception Breakpoints', 'cmd': 'call yac_dap#toggle_exception_breakpoints()'},
  \ {'label': 'DAP: Attach', 'cmd': 'call yac_dap#attach()'},
  \ {'label': 'DAP: Panel Toggle', 'cmd': 'call yac_dap#panel_toggle()'},
  \ ]

" ============================================================================
" Mode registrations (at script load time, triggered by yac_picker_modes#_init)
" ============================================================================

call yac_picker#register_mode({
  \ 'prefix': '',
  \ 'label': 'YacPicker',
  \ 'debounce': 50,
  \ 'local': 0,
  \ 'daemon_mode': 'file',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no results)',
  \ 'empty_query_msg': '  (type to search files...)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '/',
  \ 'label': 'Grep',
  \ 'debounce': 200,
  \ 'local': 0,
  \ 'daemon_mode': 'grep',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 1,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no matches)',
  \ 'empty_query_msg': '  (type to grep...)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '#',
  \ 'label': 'Symbols',
  \ 'debounce': 50,
  \ 'local': 0,
  \ 'daemon_mode': 'workspace_symbol',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no symbols found)',
  \ 'empty_query_msg': '  (no symbols found)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '@',
  \ 'label': 'Document',
  \ 'debounce': 30,
  \ 'local': 0,
  \ 'daemon_mode': 'document_symbol',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no symbols found)',
  \ 'empty_query_msg': '  (no symbols found)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '%',
  \ 'label': 'Theme',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'theme',
  \ 'query_fn': function('s:query_themes'),
  \ 'accept_fn': function('s:accept_theme'),
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no themes found in ~/.local/share/yac/themes/)',
  \ 'empty_query_msg': '  (no themes found in ~/.local/share/yac/themes/)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '!',
  \ 'label': 'MRU',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'mru',
  \ 'query_fn': function('yac_picker_mru#query'),
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no recent files)',
  \ 'empty_query_msg': '  (no recent files)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': ':',
  \ 'label': 'Buffer',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'buffer_search',
  \ 'query_fn': function('s:query_buffer'),
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no matching lines)',
  \ 'empty_query_msg': '  (type to search current buffer...)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '?',
  \ 'label': 'Help',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'help',
  \ 'query_fn': function('s:query_help'),
  \ 'accept_fn': function('s:accept_help'),
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no matching modes)',
  \ 'empty_query_msg': '',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '>',
  \ 'label': 'Commands',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'commands',
  \ 'query_fn': function('s:query_commands'),
  \ 'accept_fn': function('s:accept_command'),
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no matching commands)',
  \ 'empty_query_msg': '',
  \ })
