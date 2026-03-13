" ============================================================================
" E2E Test: DAP Debugging
" ============================================================================
" Tests: breakpoint → start → stopped → chain (panel update with variables)

call yac_test#begin('dap_basic')
call yac_test#setup()

" Create a simple Python test file in the workspace
let s:test_py = getcwd() . '/test_dap_target.py'
call writefile([
      \ 'import time',
      \ 'x = 1',
      \ 'y = 2',
      \ 'z = x + y',
      \ 'print(z)',
      \ ], s:test_py)

execute 'edit! ' . s:test_py
" Let daemon connect and settle
sleep 2000m

" ============================================================================
" Test 1: Breakpoint toggle works
" ============================================================================
call yac_test#log('INFO', 'Test 1: Toggle breakpoint')
call cursor(3, 1)
call yac_dap#toggle_breakpoint()

let signs = sign_getplaced('%', {'name': 'YacDapBreakpoint'})
let has_bp_sign = !empty(signs) && !empty(get(signs[0], 'signs', []))
call yac_test#assert_true(has_bp_sign, 'Breakpoint sign should appear on line 3')

" ============================================================================
" Test 2: DAP start sends notification
" ============================================================================
call yac_test#log('INFO', 'Test 2: DAP start')

" Start DAP session
call yac_dap#start()
call yac_test#log('INFO', 'DAP start called')

" Wait for session to be active
let dap_active = yac_test#wait_for(
      \ {-> yac_dap#statusline() !=# ''},
      \ 10000)
call yac_test#assert_true(dap_active, 'DAP statusline should be non-empty after start')
call yac_test#log('INFO', 'DAP statusline: ' . yac_dap#statusline())

" ============================================================================
" Test 3: Wait for stopped event (breakpoint hit)
" ============================================================================
call yac_test#log('INFO', 'Test 3: Wait for stopped event')

let dap_stopped = yac_test#wait_for(
      \ {-> yac_dap#statusline() =~# 'stopped'},
      \ 15000)
call yac_test#assert_true(dap_stopped,
      \ 'DAP should stop at breakpoint (statusline contains stopped)')
call yac_test#log('INFO', 'Final DAP statusline: ' . yac_dap#statusline())

" ============================================================================
" Test 4: Chain completion — panel_data has frames and variables
" ============================================================================
call yac_test#log('INFO', 'Test 4: Wait for chain (panel update)')

" s:panel_data is script-local; access via statusline which includes file:line
" after on_panel_update sets s:current_file and s:current_line
let has_location = yac_test#wait_for(
      \ {-> yac_dap#statusline() =~# 'test_dap_target'},
      \ 10000)
call yac_test#assert_true(has_location,
      \ 'Statusline should show file name after chain completes')
call yac_test#log('INFO', 'Statusline after chain: ' . yac_dap#statusline())

" Verify cursor jumped to breakpoint line
let has_line3 = yac_dap#statusline() =~# ':3\>'
call yac_test#assert_true(has_line3,
      \ 'Statusline should show line 3 (breakpoint location)')

" ============================================================================
" Test 5: Panel data accessible via dap_get_panel
" ============================================================================
call yac_test#log('INFO', 'Test 5: Panel data via dap_get_panel')

" Request panel data directly from daemon
let g:yac_test_panel = {}
function! s:on_panel_result(ch, msg) abort
  let g:yac_test_panel = a:msg
endfunction
call yac#send_request('dap_get_panel', {}, function('s:on_panel_result'))

let has_panel = yac_test#wait_for(
      \ {-> !empty(g:yac_test_panel)},
      \ 5000)
call yac_test#assert_true(has_panel, 'dap_get_panel should return data')

if has_panel
  let panel = g:yac_test_panel
  call yac_test#log('INFO', 'Panel keys: ' . string(keys(panel)))

  " Check status
  let status = get(panel, 'status', {})
  call yac_test#assert_true(get(status, 'state', '') ==# 'stopped',
        \ 'Panel status.state should be stopped')

  " Check frames
  let frames = get(panel, 'frames', [])
  call yac_test#assert_true(len(frames) > 0,
        \ 'Panel should have at least 1 stack frame')
  if len(frames) > 0
    call yac_test#log('INFO', 'Top frame: ' . string(frames[0]))
  endif

  " Check variables
  let vars = get(panel, 'variables', [])
  call yac_test#assert_true(len(vars) > 0,
        \ 'Panel should have variables (locals at breakpoint)')
  call yac_test#log('INFO', 'Variable count: ' . string(len(vars)))
  let show_count = len(vars) > 4 ? 4 : len(vars)
  for i in range(show_count)
    try
      let v = vars[i]
      call yac_test#log('INFO', '  var: ' . string(get(v, 'name', '?')) . ' = ' . string(get(v, 'value', '?')))
    catch
      call yac_test#log('INFO', '  var[' . i . '] error: ' . v:exception)
    endtry
  endfor
endif

" ============================================================================
" Test 6: Current line sign placed at breakpoint
" ============================================================================
call yac_test#log('INFO', 'Test 6: Current line sign')
let cur_signs = sign_getplaced('%', {'name': 'YacDapCurrentLine'})
let has_cur = !empty(cur_signs) && !empty(get(cur_signs[0], 'signs', []))
call yac_test#assert_true(has_cur, 'Current line sign should be placed at stopped position')

" ============================================================================
" Test 7: Messages contain DAP callback evidence
" ============================================================================
call yac_test#check_errors()
call yac_test#log('INFO', 'Test 7: Check messages')
redir => msgs
silent messages
redir END
for line in split(msgs, "\n")
  if line =~# '\cyac\|dap\|debug\|stop\|break\|panel'
    call yac_test#log('INFO', '  MSG: ' . line)
  endif
endfor

" ============================================================================
" Cleanup
" ============================================================================
silent! call yac_dap#terminate()
sleep 500m
call delete(s:test_py)
call yac_test#teardown()
call yac_test#end()
