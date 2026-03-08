" ============================================================================
" E2E Test: Diagnostics — Virtual text toggle and clear
" ============================================================================

call yac_test#begin('diagnostics_virtual_text')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Virtual text is enabled by default
" ============================================================================
call yac_test#log('INFO', 'Test 1: Virtual text default state')

let s:vtext_default = get(g:, 'yac_diagnostic_virtual_text', -1)
call yac_test#assert_true(s:vtext_default == 1 || s:vtext_default == -1,
  \ printf('Virtual text should be enabled by default (got %d)', s:vtext_default))

" ============================================================================
" Test 2: Introduce error and verify virtual text appears
" ============================================================================
call yac_test#log('INFO', 'Test 2: Virtual text appears with diagnostics')

let g:yac_diagnostic_virtual_text = 1

normal! G
normal! o
execute "normal! iconst vtext_err: i32 = \"not a number\";"
silent write

let s:got_diag = yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)},
  \ 8000, 'Diagnostics should arrive for virtual text test')

if s:got_diag
  " Check for diagnostic text properties
  let s:vtext_count = 0
  for lnum in range(1, line('$'))
    let props = prop_list(lnum)
    for p in props
      if get(p, 'type', '') =~# '^diagnostic_'
        let s:vtext_count += 1
      endif
    endfor
  endfor
  call yac_test#assert_true(s:vtext_count > 0,
    \ printf('Should have diagnostic props (found %d)', s:vtext_count))
endif

" ============================================================================
" Test 3: Clear virtual text explicitly
" ============================================================================
call yac_test#log('INFO', 'Test 3: Clear virtual text')

if s:got_diag && exists(':YacClearDiagnosticVirtualText')
  YacClearDiagnosticVirtualText

  let s:after_clear = 0
  for lnum in range(1, line('$'))
    for p in prop_list(lnum)
      " Only count virtual text props, not underlines
      if get(p, 'type', '') =~# '^diagnostic_vt_'
        let s:after_clear += 1
      endif
    endfor
  endfor
  call yac_test#assert_true(s:after_clear == 0,
    \ 'Clear should remove virtual text props (remaining: ' . s:after_clear . ')')
else
  call yac_test#skip('clear_vtext', 'No diagnostics to clear or command unavailable')
endif

" ============================================================================
" Test 4: Toggle off then on
" ============================================================================
call yac_test#log('INFO', 'Test 4: Toggle virtual text off and on')

if exists(':YacToggleDiagnosticVirtualText')
  let v:errmsg = ''
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(v:errmsg ==# '', 'Toggle off should not error')

  let v:errmsg = ''
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(v:errmsg ==# '', 'Toggle on should not error')
else
  call yac_test#skip('toggle_vtext', 'Command unavailable')
endif

" ============================================================================
" Cleanup
" ============================================================================
silent! %d
call setline(1, s:original_content)
silent write

" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
