" ============================================================================
" Unit Test: Command Palette — verify s:yac_commands completeness
" ============================================================================

call yac_test#begin('command_palette')

" ============================================================================
" Test 1: All user-facing commands should be in the command palette
" ============================================================================
call yac_test#log('INFO', 'Test 1: Command palette completeness')

let s:commands = yac_picker#get_commands()
let s:labels = map(copy(s:commands), 'v:val.label')

" LSP Navigation
for s:expected in ['Definition', 'Declaration', 'Type Definition', 'Implementation',
      \ 'References', 'Peek Definition']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" LSP Editing
for s:expected in ['Rename', 'Code Action', 'Format', 'Range Format']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" LSP Info
for s:expected in ['Hover', 'Document Symbols', 'Signature Help',
      \ 'Inlay Hints Toggle', 'Folding Range']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" LSP Hierarchy
for s:expected in ['Call Hierarchy Incoming', 'Call Hierarchy Outgoing',
      \ 'Type Hierarchy Supertypes', 'Type Hierarchy Subtypes']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" Diagnostics
for s:expected in ['Diagnostic Virtual Text Toggle']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" Tree-sitter
for s:expected in ['Tree-sitter Symbols', 'Tree-sitter Highlights Toggle']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" Picker
for s:expected in ['File Picker', 'Grep']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" Theme
for s:expected in ['Theme Picker', 'Theme Default']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" Copilot
for s:expected in ['Copilot Sign In', 'Copilot Sign Out', 'Copilot Status',
      \ 'Copilot Enable', 'Copilot Disable']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" LSP Management
for s:expected in ['LSP Install', 'LSP Update', 'LSP Status', 'Restart LSP']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" Daemon / Debug
for s:expected in ['Open Log', 'Connections', 'Stop Daemon',
      \ 'Debug Toggle', 'Debug Status']
  call yac_test#assert_true(
    \ index(s:labels, s:expected) >= 0,
    \ 'command palette should have "' . s:expected . '"')
endfor

" ============================================================================
" Test 2: Every command entry should have both 'label' and 'cmd' keys
" ============================================================================
call yac_test#log('INFO', 'Test 2: Command entry structure')

for s:entry in s:commands
  call yac_test#assert_true(
    \ has_key(s:entry, 'label') && has_key(s:entry, 'cmd'),
    \ 'command entry should have label and cmd keys: ' . string(s:entry))
  call yac_test#assert_true(
    \ !empty(s:entry.label) && !empty(s:entry.cmd),
    \ 'command entry label and cmd should not be empty: ' . s:entry.label)
endfor

" ============================================================================
" Test 3: No duplicate labels
" ============================================================================
call yac_test#log('INFO', 'Test 3: No duplicate labels')

let s:seen = {}
for s:entry in s:commands
  call yac_test#assert_true(
    \ !has_key(s:seen, s:entry.label),
    \ 'duplicate label found: ' . s:entry.label)
  let s:seen[s:entry.label] = 1
endfor

" ============================================================================
" Test 4: Commands should be grouped logically (categories)
"   Verify ordering: LSP Nav → LSP Edit → LSP Info → Hierarchy →
"   Diagnostics → TS → Picker → Theme → Copilot → LSP Mgmt → Daemon
" ============================================================================
call yac_test#log('INFO', 'Test 4: Category ordering')

" Find indices of representative commands from each group
let s:idx_definition = index(s:labels, 'Definition')
let s:idx_rename = index(s:labels, 'Rename')
let s:idx_hover = index(s:labels, 'Hover')
let s:idx_copilot = index(s:labels, 'Copilot Sign In')
let s:idx_open_log = index(s:labels, 'Open Log')

" Navigation before editing
call yac_test#assert_true(
  \ s:idx_definition < s:idx_rename,
  \ 'Navigation commands should come before editing commands')

" Editing before info
call yac_test#assert_true(
  \ s:idx_rename < s:idx_hover,
  \ 'Editing commands should come before info commands')

" Copilot before daemon management
call yac_test#assert_true(
  \ s:idx_copilot < s:idx_open_log,
  \ 'Copilot commands should come before daemon commands')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
