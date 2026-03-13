" ============================================================================
" E2E Test: DAP Debugging
" ============================================================================
" Tests: F5 → start session → breakpoint hit → on_stopped callback

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

" Use a global to detect if on_stopped fires
let g:yac_test_dap_stopped = 0
let g:yac_test_dap_stopped_reason = ''

" Monkey-patch on_stopped to also set our test flag
" (The real function still runs; we hook at the beginning)
function! s:orig_on_stopped_wrapper(...) abort
  let g:yac_test_dap_stopped = 1
  let body = a:0 > 0 ? a:1 : {}
  let g:yac_test_dap_stopped_reason = get(body, 'reason', 'unknown')
  call yac_test#log('INFO', 'on_stopped fired! reason=' . g:yac_test_dap_stopped_reason)
endfunction

" Save original and override
let s:Orig_on_stopped = function('yac_dap#on_stopped')
" We can't easily replace an autoload function; instead observe via messages

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

" Wait for the stopped state — on_stopped sets s:dap_state = 'stopped'
" which is reflected in yac_dap#statusline()
let dap_stopped = yac_test#wait_for(
      \ {-> yac_dap#statusline() =~# 'stopped'},
      \ 15000)
call yac_test#assert_true(dap_stopped,
      \ 'DAP should stop at breakpoint (statusline contains stopped)')
call yac_test#log('INFO', 'Final DAP statusline: ' . yac_dap#statusline())

" ============================================================================
" Test 4: Check messages for callback evidence
" ============================================================================
call yac_test#log('INFO', 'Test 4: Check messages')
redir => msgs
silent messages
redir END
call yac_test#log('INFO', 'Messages dump:')
for line in split(msgs, "\n")
  if line =~# '\cyac\|dap\|debug\|stop\|break'
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
