" ============================================================================
" E2E Test: Signature Help
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('signature')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 15000)

" ============================================================================
" Test 1: ( triggers signature help
" ============================================================================
call yac_test#log('INFO', 'Test 1: ( should trigger signature help')

" 在 main() 函数体内输入 createUserMap(
" main() 起始行大约是 56，在函数体内插入
call cursor(56, 1)
normal! O
execute "normal! i    const m = createUserMap("

" 签名帮助是 100ms debounce + LSP 请求，需要等待
let s:sig_ok = 0
let s:sig_elapsed = 0
while s:sig_elapsed < 15000
  call popup_clear()
  " 手动触发签名帮助（模拟 TextChangedI 调用）
  call yac#signature_help()
  if yac_test#wait_for({-> yac#get_signature_popup_id() != -1}, 5000)
    let s:sig_ok = 1
    break
  endif
  let s:sig_elapsed += 3000
endwhile

if s:sig_ok
  call yac_test#log('INFO', 'Signature popup appeared')
  call yac_test#assert_true(1, 'Signature popup should appear after (')
else
  call yac_test#log('INFO', 'No signature popup after 10s')
  call yac_test#assert_true(0, 'Signature popup should appear after (')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 2: Signature shows correct function label
" ============================================================================
call yac_test#log('INFO', 'Test 2: Signature label for User.init')

call cursor(56, 1)
normal! O
execute "normal! i    const u = User.init("

let s:sig_ok2 = 0
let s:sig_elapsed2 = 0
while s:sig_elapsed2 < 15000
  call popup_clear()
  call yac#signature_help()
  if yac_test#wait_for({-> yac#get_signature_popup_id() != -1}, 5000)
    let s:sig_ok2 = 1
    break
  endif
  let s:sig_elapsed2 += 3000
endwhile

if s:sig_ok2
  " 验证 popup 内容包含参数信息
  let s:sig_popup = yac#get_signature_popup_id()
  let s:sig_content = getbufline(winbufnr(s:sig_popup), 1, '$')
  call yac_test#log('INFO', printf('Signature content: %s', string(s:sig_content)))
  " 签名应包含 init 和参数名
  let s:sig_text = join(s:sig_content, ' ')
  call yac_test#assert_match(s:sig_text, 'init\|id\|name', 'Signature should show function params')
else
  call yac_test#assert_true(0, 'Signature popup should appear for User.init(')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 3: Completion popup open → ( typed → completion closes, signature opens
" ============================================================================
call yac_test#log('INFO', 'Test 3: ( closes completion and triggers signature')

call cursor(56, 1)
normal! O
execute "normal! i    const m = createUserMap"

" 先触发补全（输入了 createUserMap，前缀足够长）
let s:comp_ok = 0
let s:comp_elapsed = 0
while s:comp_elapsed < 15000
  call popup_clear()
  YacComplete
  if yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 3000)
    let s:comp_ok = 1
    break
  endif
  let s:comp_elapsed += 3000
endwhile

call yac_test#log('INFO', printf('Completion popup appeared: %d', s:comp_ok))

if s:comp_ok
  " 补全弹窗已打开，现在追加 (
  " 不能用 normal! a( 因为 InsertLeave 会关闭弹窗
  " 用 setline 模拟文本变更
  let s:cur_line = line('.')
  call setline(s:cur_line, getline(s:cur_line) . '(')
  call cursor(s:cur_line, col('$'))

  " 模拟 TextChangedI: auto_complete_trigger 应关闭补全弹窗
  call yac#auto_complete_trigger()
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1,
    \ 'Completion popup should close when ( is typed')

  " 然后 signature_help_trigger 应触发签名帮助
  " 注意：在测试环境 mode()='c'，signature_help_trigger 会因 mode check 返回
  " 所以直接调用 yac#signature_help() 模拟
  call yac#signature_help()
  let s:sig_appeared = yac_test#wait_for({-> yac#get_signature_popup_id() != -1}, 5000)
  call yac_test#assert_true(s:sig_appeared,
    \ 'Signature popup should appear after ( when completion was open')
else
  call yac_test#assert_true(0, 'Completion popup should appear first for createUserMap')
  call yac_test#assert_true(0, 'Skipped: signature after completion close')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Cleanup
" ============================================================================
silent! %d
edit!

call yac_test#teardown()
call yac_test#end()
