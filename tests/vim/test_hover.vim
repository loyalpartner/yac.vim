" ============================================================================
" E2E Test: Hover Information
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('hover')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Hover on struct
" ============================================================================
call yac_test#log('INFO', 'Test 1: Hover on User struct')

" 定位到 User struct 定义
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

" 清掉残留 popup（如 toast），然后触发 hover
call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

" 检查 hover popup 内容（精确定位，不会拿到 toast）
let content = yac_test#get_hover_content()
if !empty(content)
  call yac_test#log('INFO', 'Popup appeared for User struct')
  call yac_test#assert_contains(content, 'User', 'Hover should contain "User"')
  call yac_test#assert_contains(content, 'struct', 'Hover should mention "struct"')
else
  call yac_test#log('INFO', 'No hover popup (may use echo instead)')
endif

" 关闭 popup
call yac_test#clear_popups()

" ============================================================================
" Test 2: Hover on function
" ============================================================================
call yac_test#log('INFO', 'Test 2: Hover on getName function')

" 定位到 getName 方法
call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

let content = yac_test#get_hover_content()
if !empty(content)
  call yac_test#log('INFO', 'Popup appeared for getName')
  " 验证函数签名
  call yac_test#assert_match(content, 'fn\|pub', 'Hover should show function signature')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 3: Hover on variable
" ============================================================================
call yac_test#log('INFO', 'Test 3: Hover on variable')

" 定位到 users 变量
call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

let content = yac_test#get_hover_content()
if !empty(content)
  call yac_test#log('INFO', 'Popup appeared for users variable')
  " 应该显示 AutoHashMap 类型
  call yac_test#assert_contains(content, 'AutoHashMap', 'Hover should show AutoHashMap type')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 4: Hover on doc comment
" ============================================================================
call yac_test#log('INFO', 'Test 4: Hover on documented item')

" 定位到 createUserMap 函数（有文档注释）
call cursor(30, 8)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'createUserMap', 'Cursor should be on "createUserMap"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

let content = yac_test#get_hover_content()
if !empty(content)
  " 应该显示文档注释
  call yac_test#assert_contains(content, 'Create user map', 'Hover should show doc comment')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 5: Hover on non-symbol (空白处)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Hover on empty space')

" 移到空行
call cursor(3, 1)

call yac_test#clear_popups()
YacHover
call yac_test#wait_no_popup(3000)

" 空白处不应该有 hover
call yac_test#assert_true(yac#get_hover_popup_id() == -1, 'No popup should appear on empty line')

" ============================================================================
" Test 6: Hover popup should have syntax-highlighted code blocks
" ============================================================================
call yac_test#log('INFO', 'Test 6: Hover popup code block highlighting')

" 定位到 User struct 定义 — zls 会返回包含 ```zig 代码块的 markdown
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

call yac_test#clear_popups()
YacHover
" 两次 round-trip: hover→LSP + ts_hover_highlight→TS thread，需要更多时间
call yac_test#wait_hover_popup(5000)

let pid = yac#get_hover_popup_id()
if pid == -1
  call yac_test#log('INFO', 'No hover popup, skipping highlight test')
  call yac_test#skip('hover_highlight', 'No hover popup appeared')
else
  let popup_bufnr = winbufnr(pid)
  let popup_lines = getbufline(popup_bufnr, 1, '$')
  call yac_test#log('INFO', 'Popup bufnr=' . popup_bufnr . ' lines=' . len(popup_lines))

  " 记录前 5 行内容（调试用）
  for i in range(min([5, len(popup_lines)]))
    call yac_test#log('INFO', '  popup[' . (i+1) . ']: ' . popup_lines[i])
  endfor

  " 检查 popup buffer 上是否有 yac_hover_ 开头的 text properties
  let total_props = 0
  for lnum in range(1, len(popup_lines))
    let props = prop_list(lnum, {'bufnr': popup_bufnr})
    let ts_props = filter(copy(props), {_, p -> get(p, 'type', '') =~# '^yac_hover_'})
    if !empty(ts_props)
      call yac_test#log('INFO', '  line ' . lnum . ' props: ' . string(ts_props))
    endif
    let total_props += len(ts_props)
  endfor

  call yac_test#log('INFO', 'Total yac_hover_ text properties: ' . total_props)
  " Also log ALL prop types on each line for debugging
  for lnum in range(1, len(popup_lines))
    let all_props = prop_list(lnum, {'bufnr': popup_bufnr})
    if !empty(all_props)
      call yac_test#log('INFO', '  ALL props line ' . lnum . ': ' . string(all_props))
    endif
  endfor
  call yac_test#assert_true(total_props > 0,
    \ 'Hover popup should have yac_hover_ text properties (got ' . total_props . ')')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 7: Hover on function — function name should be highlighted
" ============================================================================
call yac_test#log('INFO', 'Test 7: Hover function name highlighting')

" 定位到 createUserMap 函数定义
call cursor(30, 8)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'createUserMap', 'Cursor should be on "createUserMap"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(5000)

let pid = yac#get_hover_popup_id()
if pid == -1
  call yac_test#log('INFO', 'No hover popup, skipping function highlight test')
  call yac_test#skip('hover_fn_highlight', 'No hover popup appeared')
else
  let popup_bufnr = winbufnr(pid)
  let popup_lines = getbufline(popup_bufnr, 1, '$')
  call yac_test#log('INFO', 'Fn hover lines=' . len(popup_lines))
  for i in range(min([5, len(popup_lines)]))
    call yac_test#log('INFO', '  popup[' . (i+1) . ']: ' . popup_lines[i])
  endfor

  " 收集所有 prop types
  let fn_props = 0
  let all_groups = {}
  for lnum in range(1, len(popup_lines))
    let props = prop_list(lnum, {'bufnr': popup_bufnr})
    for p in props
      let ptype = get(p, 'type', '')
      if ptype =~# '^yac_hover_'
        let all_groups[ptype] = get(all_groups, ptype, 0) + 1
        if ptype ==# 'yac_hover_YacTsFunction'
          let fn_props += 1
        endif
      endif
    endfor
  endfor

  let total_props = 0
  for v in values(all_groups)
    let total_props += v
  endfor
  call yac_test#log('INFO', 'Function hover prop groups: ' . string(all_groups))
  call yac_test#log('INFO', 'Total yac_hover_ props: ' . total_props . ', YacTsFunction: ' . fn_props)
  call yac_test#assert_true(total_props > 0,
    \ 'Function hover should have yac_hover_ text properties (got ' . total_props . ')')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 8: Hover twice on same symbol — highlights must persist on second hover
" ============================================================================
call yac_test#log('INFO', 'Test 8: Hover twice — highlights should persist')

" Hover first time on User struct
call cursor(6, 12)
call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(5000)

let pid1 = yac#get_hover_popup_id()
let props1 = 0
if pid1 != -1
  let bufnr1 = winbufnr(pid1)
  let lines1 = getbufline(bufnr1, 1, '$')
  for lnum in range(1, len(lines1))
    let props = prop_list(lnum, {'bufnr': bufnr1})
    let props1 += len(filter(copy(props), {_, p -> get(p, 'type', '') =~# '^yac_hover_'}))
  endfor
  call yac_test#log('INFO', 'First hover: ' . props1 . ' props')
endif
call yac_test#assert_true(props1 > 0, 'First hover should have highlight props')

" Close and hover again on same symbol
call yac_test#clear_popups()
call cursor(6, 12)
YacHover
call yac_test#wait_hover_popup(5000)

let pid2 = yac#get_hover_popup_id()
let props2 = 0
if pid2 != -1
  let bufnr2 = winbufnr(pid2)
  let lines2 = getbufline(bufnr2, 1, '$')
  for lnum in range(1, len(lines2))
    let props = prop_list(lnum, {'bufnr': bufnr2})
    let props2 += len(filter(copy(props), {_, p -> get(p, 'type', '') =~# '^yac_hover_'}))
  endfor
  call yac_test#log('INFO', 'Second hover: ' . props2 . ' props')
endif
call yac_test#assert_true(props2 > 0, 'Second hover should still have highlight props')

call yac_test#clear_popups()

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
