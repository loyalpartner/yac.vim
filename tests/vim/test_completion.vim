" ============================================================================
" E2E Test: Code Completion
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('completion')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 15000)

" ============================================================================
" Test 1: Method completion (User.)
" ============================================================================
call yac_test#log('INFO', 'Test 1: Method completion on User.')

" 在 processUser 函数体内插入 User. 触发成员补全
" zls 在模块顶层不会返回类型成员，需要在函数体内才能解析
call cursor(46, 1)
normal! O
execute "normal! i    const x = User."

" zls 冷缓存下需要时间索引类型信息，用重试循环
let s:method_ok = 0
let s:method_elapsed = 0
while s:method_elapsed < 20000
  call popup_clear()
  YacComplete
  if yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)
    let s:method_ok = 1
    break
  endif
  let s:method_elapsed += 3000
endwhile

if s:method_ok
  call yac_test#log('INFO', 'Method completion popup appeared')
  call yac_test#assert_true(1, 'Completion popup should appear for User.')
else
  call yac_test#log('INFO', 'No completion popup for User. after 20s retries')
  call yac_test#assert_true(0, 'Completion popup should appear for User.')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 2: Import completion (@import)
" ============================================================================
call yac_test#log('INFO', 'Test 2: Import completion')

normal! gg
normal! O
execute "normal! iconst x = @import(\"s"

YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 5000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Import completion triggered')
  call yac_test#assert_true(1, 'Import completion should trigger')
else
  call yac_test#assert_true(0, 'Import completion should trigger')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 3: Local variable completion
" ============================================================================
call yac_test#log('INFO', 'Test 3: Local variable completion')

" 在 process_user 函数中测试
call cursor(45, 1)
normal! O
execute "normal! i    const name = us"
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 5000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Local variable completion triggered')
  call yac_test#assert_true(1, 'Local variable completion should trigger')
else
  call yac_test#assert_true(0, 'Local variable completion should trigger')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 4: CR accepts completion and inserts text
" ============================================================================
call yac_test#log('INFO', 'Test 4: CR accepts completion')

" 进入插入模式，输入前缀
call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

" 注入模拟补全响应
let s:mock_items = [
  \ {'label': 'user', 'kind': 'Variable', 'insertText': 'user'},
  \ {'label': 'username', 'kind': 'Variable', 'insertText': 'username'},
  \ {'label': 'users', 'kind': 'Variable', 'insertText': 'users'},
  \ ]
call yac#test_inject_completion_response(s:mock_items)

" 等待弹窗出现
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Completion popup should appear after inject')

if s:popup_appeared
  " CR 接受第一个补全项（直接调用 handler）
  " 注意：文本插入需要 mode()=='i'（<Cmd> 上下文），脚本无法模拟
  " 所以只验证弹窗关闭和状态重置
  call yac#test_do_cr()

  " 弹窗应该关闭
  let state = yac#get_completion_state()
  call yac_test#assert_eq(state.popup_id, -1, 'Popup should be closed after CR accept')
  call yac_test#assert_true(empty(state.items), 'Items should be cleared after CR accept')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 5: CR passes through when no popup
" ============================================================================
call yac_test#log('INFO', 'Test 5: CR passthrough without popup')

call cursor(46, 1)
normal! O
execute "normal! i    const x = 1"
let s:line_before = line('.')

" 确认无弹窗
call yac_test#assert_eq(yac#get_completion_state().popup_id, -1, 'No popup before CR passthrough')

" CR 应该 feedkeys 换行（无弹窗时 do_cr fallback 到 feedkeys）
call yac#test_do_cr()

" 确认弹窗状态未变
call yac_test#assert_eq(yac#get_completion_state().popup_id, -1, 'No popup after CR passthrough')

execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 6: Esc closes popup and stays in insert mode
" ============================================================================
call yac_test#log('INFO', 'Test 6: Esc closes popup')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Popup should appear before Esc test')

if s:popup_appeared
  call yac#test_do_esc()

  let state = yac#get_completion_state()
  call yac_test#assert_eq(state.popup_id, -1, 'Popup should be closed after Esc')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 7: C-N / C-P navigation
" ============================================================================
call yac_test#log('INFO', 'Test 7: C-N/C-P navigation')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Popup should appear for nav test')

if s:popup_appeared
  " 初始 selected=0
  call yac_test#assert_eq(yac#get_completion_state().selected, 0, 'Initial selection should be 0')

  " C-N → selected=1
  call yac#test_do_nav(1)
  call yac_test#assert_eq(yac#get_completion_state().selected, 1, 'After C-N selection should be 1')

  " C-N → selected=2
  call yac#test_do_nav(1)
  call yac_test#assert_eq(yac#get_completion_state().selected, 2, 'After 2x C-N selection should be 2')

  " C-P → back to selected=1
  call yac#test_do_nav(-1)
  call yac_test#assert_eq(yac#get_completion_state().selected, 1, 'After C-P selection should be 1')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 8: Ghost popup prevention — async response after close
" ============================================================================
call yac_test#log('INFO', 'Test 8: Ghost popup prevention')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

" 打开弹窗
call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Popup should appear for ghost test')

if s:popup_appeared
  " 用户按 Esc 关闭弹窗 — suppress_until 被设置
  call yac#test_do_esc()
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1, 'Popup closed')

  " 模拟延迟到达的异步响应（经过 suppress 守卫）
  call yac#test_inject_async_response(s:mock_items)
  sleep 50m

  " 弹窗不应重新打开（suppress_until 保护）
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1, 'Ghost popup should not appear')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 9: Sequential completions — state is clean
" ============================================================================
call yac_test#log('INFO', 'Test 9: Sequential completions')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

" 第一次补全
call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'First popup should appear')

if s:popup_appeared
  " 接受补全
  call yac#test_do_cr()
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1, 'First popup closed after accept')

  " 等待 suppress 窗口过期再触发第二次（suppress = 0.5s，多留余量）
  sleep 800m

  " 第二次补全 — 使用与当前前缀匹配的项
  " insert_completion 在 mode()!='i' 时不修改文本，所以前缀仍然是 "us"
  let s:mock_items_2 = [
    \ {'label': 'use_thing', 'kind': 'Variable', 'insertText': 'use_thing'},
    \ {'label': 'user_data', 'kind': 'Variable', 'insertText': 'user_data'},
    \ ]
  call yac#test_inject_completion_response(s:mock_items_2)
  let s:popup2 = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
  call yac_test#assert_true(s:popup2, 'Second popup should appear after suppress expires')

  if s:popup2
    let state2 = yac#get_completion_state()
    call yac_test#assert_eq(state2.selected, 0, 'Second popup selection should start at 0')
    call yac_test#assert_true(len(state2.items) > 0, 'Second popup should have items')
  endif
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 10: E2E — std. 成员补全 vs const x = std.
" ============================================================================
call yac_test#log('INFO', 'Test 10: std. member completion context comparison')

" --- 10a: 'std.' 不带前缀 ---
call cursor(56, 1)
normal! O
execute "normal! i    std."

let s:dot_ok = 0
let s:dot_items = []
let s:dot_elapsed = 0
while s:dot_elapsed < 10000
  call popup_clear()
  YacComplete
  if yac_test#wait_for({-> !empty(popup_list())}, 3000)
    let s:dot_ok = 1
    " 收集补全项
    let s:dot_items = yac#get_completion_state().items
    break
  endif
  let s:dot_elapsed += 3000
endwhile

call yac_test#log('INFO', printf('10a: std. popup=%d items=%d', s:dot_ok, len(s:dot_items)))
if s:dot_ok && !empty(s:dot_items)
  let s:dot_labels = map(copy(s:dot_items), {_, v -> v.label})
  call yac_test#log('INFO', printf('10a labels: %s', string(s:dot_labels[:min([9, len(s:dot_labels)-1])])))
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" --- 10b: 'const x = std.' 带前缀 ---
call cursor(56, 1)
normal! O
execute "normal! i    const x = std."

let s:ctx_ok = 0
let s:ctx_items = []
let s:ctx_elapsed = 0
while s:ctx_elapsed < 10000
  call popup_clear()
  YacComplete
  if yac_test#wait_for({-> !empty(popup_list())}, 3000)
    let s:ctx_ok = 1
    let s:ctx_items = yac#get_completion_state().items
    break
  endif
  let s:ctx_elapsed += 3000
endwhile

call yac_test#log('INFO', printf('10b: const x = std. popup=%d items=%d', s:ctx_ok, len(s:ctx_items)))
if s:ctx_ok && !empty(s:ctx_items)
  let s:ctx_labels = map(copy(s:ctx_items), {_, v -> v.label})
  call yac_test#log('INFO', printf('10b labels: %s', string(s:ctx_labels[:min([9, len(s:ctx_labels)-1])])))
endif

" 两种方式都应该能补出成员
call yac_test#assert_true(s:dot_ok, 'std. should show completion popup')
call yac_test#assert_true(s:ctx_ok, 'const x = std. should show completion popup')

" 两种方式的补全项数量应该相同（或至少 std. 也能补出成员）
if s:dot_ok && s:ctx_ok
  call yac_test#assert_eq(len(s:dot_items), len(s:ctx_items),
    \ printf('std. (%d items) should match const x = std. (%d items)', len(s:dot_items), len(s:ctx_items)))
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 11: Stale response race — users 响应在输入 . 后到达应被丢弃
" ============================================================================
call yac_test#log('INFO', 'Test 10: Stale response race (users. scenario)')

call cursor(46, 1)
normal! O
execute "normal! i    const x = users."

" 模拟场景：用户输入 users. → 旧的 users 补全请求的响应先到达
" seq 已经被 auto_complete_trigger 递增（输入 . 时）
let s:old_seq = yac#test_get_seq()
" 模拟 auto_complete_trigger 在输入 . 时递增 seq
let s:new_seq = yac#test_bump_seq()
call yac_test#log('INFO', printf('old_seq=%d, new_seq=%d', s:old_seq, s:new_seq))

" 旧请求（seq=old_seq, 对应 users 前缀）的响应到达 — 应被丢弃
let s:global_items = [
  \ {'label': 'user', 'kind': 'Variable', 'insertText': 'user'},
  \ {'label': 'username', 'kind': 'Variable', 'insertText': 'username'},
  \ ]
call yac#test_inject_response_with_seq(s:global_items, s:old_seq)
sleep 50m
call yac_test#assert_eq(yac#get_completion_state().popup_id, -1,
  \ 'Stale response (old seq) should be dropped')

" 新请求（seq=new_seq, 对应 users. 成员补全）的响应到达 — 应被接受
" 光标在 . 之后，前缀为空，所以所有成员都应匹配
let s:member_items = [
  \ {'label': 'put', 'kind': 'Method', 'insertText': 'put'},
  \ {'label': 'pop', 'kind': 'Method', 'insertText': 'pop'},
  \ ]
call yac#test_inject_response_with_seq(s:member_items, s:new_seq)
sleep 50m
let s:state10 = yac#get_completion_state()
call yac_test#assert_true(s:state10.popup_id != -1,
  \ 'Current response (new seq) should show popup')
if s:state10.popup_id != -1
  " 确认显示的是成员补全，不是全局补全
  let s:has_put = 0
  for item in s:state10.items
    if item.label ==# 'put'
      let s:has_put = 1
    endif
  endfor
  call yac_test#assert_true(s:has_put, 'Popup should contain member items (put), not global items')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 12: Popup style — signature should be borderless (like completion)
" ============================================================================
call yac_test#log('INFO', 'Test 12: Signature popup should be borderless')

" popup_getoptions 对无边框 popup 不返回 borderchars 键；
" 有边框（border: [] + borderchars）则返回 borderchars 数组。
" 所以检测 borderchars 键是否存在即可。

" 12a: 验证补全弹窗无边框（基线：应该通过）
call cursor(46, 1)
normal! O
execute "normal! i    const x = us"
call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Completion popup should appear for style test')

if s:popup_appeared
  let s:comp_opts = yac#get_completion_popup_options()
  let s:comp_has_borderchars = has_key(s:comp_opts, 'borderchars')
  call yac_test#log('INFO', printf('Completion has borderchars: %d', s:comp_has_borderchars))
  call yac_test#assert_true(!s:comp_has_borderchars, 'Completion popup should NOT have borderchars (borderless)')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" 12b: 验证签名弹窗也无边框（bug: 当前有 borderchars）
call cursor(46, 1)
normal! O
execute "normal! i    const x = createUserMap("
let s:mock_sig_response = {
  \ 'signatures': [
  \   {'label': 'fn createUserMap(allocator: Allocator) !AutoHashMap', 'parameters': [
  \     {'label': [20, 41]}
  \   ]}
  \ ],
  \ 'activeSignature': 0,
  \ 'activeParameter': 0
  \ }
call yac#test_inject_signature_response(s:mock_sig_response)

let s:sig_appeared = yac#get_signature_popup_id() != -1
call yac_test#assert_true(s:sig_appeared, 'Signature popup should appear for style test')

if s:sig_appeared
  let s:sig_opts = yac#get_signature_popup_options()
  let s:sig_has_borderchars = has_key(s:sig_opts, 'borderchars')
  call yac_test#log('INFO', printf('Signature has borderchars: %d', s:sig_has_borderchars))
  call yac_test#assert_true(!s:sig_has_borderchars, 'Signature popup should NOT have borderchars (borderless, consistent with completion)')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 13: ( should close completion popup (unblock signature help)
" ============================================================================
call yac_test#log('INFO', 'Test 13: ( should close completion popup')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

" 打开补全弹窗
call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Completion popup should appear before ( test')

if s:popup_appeared
  " 模拟用户在插入模式输入 ( 后的状态：
  " 不能用 normal! a( 因为 InsertLeave 会关闭弹窗（干扰测试）
  " 直接修改 buffer 文本并移动光标来模拟
  let s:cur_line = line('.')
  call setline(s:cur_line, getline(s:cur_line) . '(')
  call cursor(s:cur_line, col('$'))

  " 调用 auto_complete_trigger — 相当于 TextChangedI 触发
  call yac#auto_complete_trigger()
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1,
    \ 'Completion popup should close when non-word char ( is typed')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Cleanup: 恢复文件
" ============================================================================
silent! %d
edit!

call yac_test#teardown()
call yac_test#end()
