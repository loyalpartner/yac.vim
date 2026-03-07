" ============================================================================
" E2E Test: Diagnostics — Underline + virtual text display
" ============================================================================

call yac_test#begin('diagnostics_display')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Toggle commands exist and don't crash
" ============================================================================
call yac_test#log('INFO', 'Test 1: Virtual text toggle commands')

if exists(':YacToggleDiagnosticVirtualText')
  let v:errmsg = ''
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(v:errmsg ==# '', 'First toggle should not crash: ' . v:errmsg)
  let v:errmsg = ''
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(v:errmsg ==# '', 'Second toggle should not crash: ' . v:errmsg)
else
  call yac_test#skip('vtext toggle', 'Command not available')
endif

" ============================================================================
" Test 2: Clear diagnostics command
" ============================================================================
call yac_test#log('INFO', 'Test 2: Clear diagnostic virtual text')

if exists(':YacClearDiagnosticVirtualText')
  let v:errmsg = ''
  YacClearDiagnosticVirtualText
  call yac_test#assert_true(v:errmsg ==# '', 'Clear diagnostic virtual text should not crash: ' . v:errmsg)
else
  call yac_test#skip('clear diag', 'Command not available')
endif

" ============================================================================
" Test 3: Underline + virtual text render after diagnostics arrive
" ============================================================================
call yac_test#log('INFO', 'Test 3: Diagnostic rendering (underline + vtext)')

let g:yac_diagnostic_virtual_text = 1

" Introduce a type error
normal! G
normal! o
execute "normal! iconst vt_err: i32 = \"not a number\";"
silent write

" Wait for diagnostics
let s:got_diag = yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)},
  \ 8000, 'Diagnostics arrival for display test')

if s:got_diag
  let s:vtext_found = 0
  let s:underline_found = 0
  let s:diag_lines = []
  for lnum in range(1, line('$'))
    let props = prop_list(lnum)
    for p in props
      let pt = get(p, 'type', '')
      if pt =~# '^diagnostic_ul_'
        let s:underline_found += 1
      elseif pt =~# '^diagnostic_'
        let s:vtext_found += 1
      endif
    endfor
    if !empty(filter(copy(props), {_, p -> get(p, 'type', '') =~# '^diagnostic'}))
      call add(s:diag_lines, lnum)
    endif
  endfor

  call yac_test#log('INFO', printf('underline=%d vtext=%d lines=%s',
    \ s:underline_found, s:vtext_found, string(s:diag_lines)))

  call yac_test#assert_true(s:underline_found >= 1,
    \ 'Undercurl should mark error range (found ' . s:underline_found . ')')
  call yac_test#assert_true(s:vtext_found >= 1,
    \ 'Virtual text should render at end of line (found ' . s:vtext_found . ')')

  " Test 4: Toggle off clears both
  call yac_test#log('INFO', 'Test 4: Toggle off clears all diagnostic props')
  YacToggleDiagnosticVirtualText
  let s:after_toggle = 0
  for lnum in range(1, line('$'))
    for p in prop_list(lnum)
      if get(p, 'type', '') =~# '^diagnostic'
        let s:after_toggle += 1
      endif
    endfor
  endfor
  call yac_test#assert_true(s:after_toggle == 0,
    \ 'Toggle off should clear all props (found ' . s:after_toggle . ')')

  YacToggleDiagnosticVirtualText
endif

" Restore
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
