" ============================================================================
" E2E Test: Tree-sitter Highlights
" ============================================================================

call yac_test#begin('ts_highlights')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Helper functions
" ============================================================================

" 获取指定行的 tree-sitter text properties
function! s:get_ts_props(lnum) abort
  return filter(prop_list(a:lnum), {_, p -> get(p, 'type', '') =~# '^yac_ts_'})
endfunction

" 获取指定行上覆盖某列的 prop
function! s:get_prop_at(lnum, col) abort
  for p in s:get_ts_props(a:lnum)
    if p.col <= a:col && a:col < p.col + p.length
      return p
    endif
  endfor
  return {}
endfunction

" 提取 props 的 col/length/type 三元组（用于比较）
function! s:props_signature(lnum) abort
  return map(s:get_ts_props(a:lnum), {_, p -> [p.col, p.length, p.type]})
endfunction

" 重新加载干净的测试文件并等待高亮就绪
function! s:reload_and_wait() abort
  execute '%d'
  call setline(1, readfile('test_data/src/main.zig'))
  call yac#ts_highlights_invalidate()
  call yac_test#wait_for({-> !empty(s:get_ts_props(1))}, 5000)
endfunction

" ============================================================================
" Feature probe: 检测 tree-sitter highlights 是否可用
" ============================================================================
call yac#ts_highlights_enable()
let s:hl_available = yac_test#wait_for(
  \ {-> !empty(s:get_ts_props(1))}, 5000)

if !s:hl_available
  call yac_test#log('INFO', 'Tree-sitter highlights not available, skipping all tests')
  call yac_test#skip('ts_highlights', 'Feature not available')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(1, 'Tree-sitter highlights feature is available')

" ============================================================================
" Test 1: 基本高亮 — 关键字有 props
" ============================================================================
call yac_test#log('INFO', 'Test 1: Basic highlights on known tokens')

" Line 1: `const std = @import("std");`
call yac_test#wait_assert(
  \ {-> !empty(s:get_prop_at(1, 1))},
  \ 3000, 'Line 1 col 1 (const) should have a ts prop')

" ============================================================================
" Test 2: 相同内容的行应有相同的高亮签名
" ============================================================================
call yac_test#log('INFO', 'Test 2: Identical lines should have identical highlight signatures')

" Line 32-34 都是 `try users.put(N, ...)`
let s:sig32 = s:props_signature(32)
let s:sig33 = s:props_signature(33)
let s:sig34 = s:props_signature(34)

call yac_test#assert_true(!empty(s:sig32), 'Line 32 should have ts props')

" 三行结构相同（只有数字和字符串内容不同），前几个 token 的类型应一致
" 比较 "try" token (col 5) 的类型
let s:try32 = s:get_prop_at(32, 5)
let s:try33 = s:get_prop_at(33, 5)
let s:try34 = s:get_prop_at(34, 5)
if !empty(s:try32) && !empty(s:try33)
  call yac_test#assert_eq(s:try32.type, s:try33.type,
    \ '"try" on line 32 and 33 should have same prop type')
endif
if !empty(s:try32) && !empty(s:try34)
  call yac_test#assert_eq(s:try32.type, s:try34.type,
    \ '"try" on line 32 and 34 should have same prop type')
endif

" ============================================================================
" Test 3: 编辑后 invalidate — 高亮应基于新文本（核心 bug 复现）
"
"   Bug: invalidate 不 flush did_change → daemon 用旧语法树 → 高亮错位
"   验证: 在已有行之间插入新行后 invalidate，
"         新行应有高亮，且原有行的高亮位置应正确
" ============================================================================
call yac_test#log('INFO', 'Test 3: After edit + invalidate, highlights match new text')

call s:reload_and_wait()

" 记录编辑前 line 34 的签名（`try users.put(3, ...)`）
let s:sig34_before = s:props_signature(34)
call yac_test#log('INFO', 'Line 34 sig before edit: ' . string(s:sig34_before))

" 在 line 31 之后插入新行: `    var a: i32 = 0;`
call append(31, '    var a: i32 = 0;')
" 现在：line 32 = 新行, 原 line 32-34 → line 33-35

" 触发 invalidate（模拟 InsertLeave/TextChanged）
call yac#ts_highlights_invalidate()

" 等待新行（line 32）获得高亮 — 证明 daemon 解析了新文本
call yac_test#wait_assert(
  \ {-> !empty(s:get_ts_props(32))},
  \ 5000, 'New line 32 ("var a: i32 = 0;") should get ts props after invalidate')

" 验证新行的 "var" 关键字有高亮
let s:new_var_prop = s:get_prop_at(32, 5)
call yac_test#log('INFO', 'New line 32 "var" prop: ' . string(s:new_var_prop))
call yac_test#assert_true(!empty(s:new_var_prop),
  \ 'New line "var" keyword should have a ts prop')

" 验证原 line 34（现 line 35）的签名不变
let s:sig35_after = s:props_signature(35)
call yac_test#log('INFO', 'Line 35 (shifted from 34) sig after: ' . string(s:sig35_after))
call yac_test#assert_eq(s:sig35_after, s:sig34_before,
  \ 'Shifted line should keep same highlight signature after invalidate')

" ============================================================================
" Test 4: 编辑后所有相同结构的行高亮一致
"
"   复现用户截图中的问题:
"   插入行后第一个 `try users.put` 的颜色和后面的不同
" ============================================================================
call yac_test#log('INFO', 'Test 4: All similar lines have consistent highlights after edit')

" 此时:
"   line 33: `try users.put(1, ...)`  (原 line 32)
"   line 34: `try users.put(2, ...)`  (原 line 33)
"   line 35: `try users.put(3, ...)`  (原 line 34)
" 三行的 "try" 应有相同的 prop type
let s:try33_type = get(s:get_prop_at(33, 5), 'type', '')
let s:try34_type = get(s:get_prop_at(34, 5), 'type', '')
let s:try35_type = get(s:get_prop_at(35, 5), 'type', '')

call yac_test#log('INFO', 'try types: 33=' . s:try33_type . ' 34=' . s:try34_type . ' 35=' . s:try35_type)

call yac_test#assert_eq(s:try33_type, s:try34_type,
  \ 'Line 33 and 34 "try" should have same prop type')
call yac_test#assert_eq(s:try33_type, s:try35_type,
  \ 'Line 33 and 35 "try" should have same prop type')

" "users" 也应一致
let s:users33_type = get(s:get_prop_at(33, 9), 'type', '')
let s:users34_type = get(s:get_prop_at(34, 9), 'type', '')
let s:users35_type = get(s:get_prop_at(35, 9), 'type', '')

call yac_test#assert_eq(s:users33_type, s:users34_type,
  \ 'Line 33 and 34 "users" should have same prop type')
call yac_test#assert_eq(s:users33_type, s:users35_type,
  \ 'Line 33 and 35 "users" should have same prop type')

" ============================================================================
" Test 5: 语法错误行不影响周围代码的高亮一致性
"
"   复现核心问题: 插入 `users` 这样的语法错误行后，
"   周围 `try users.put(...)` 行的高亮颜色不一致
" ============================================================================
call yac_test#log('INFO', 'Test 5: Syntax error line should not break surrounding highlights')

call s:reload_and_wait()

" 记录插入前 3 行 try users.put 的 token 类型
let s:try32_before = get(s:get_prop_at(32, 5), 'type', '')
let s:try33_before = get(s:get_prop_at(33, 5), 'type', '')
let s:try34_before = get(s:get_prop_at(34, 5), 'type', '')
let s:users32_before = get(s:get_prop_at(32, 9), 'type', '')

call yac_test#log('INFO', 'Before error: try32=' . s:try32_before
  \ . ' try33=' . s:try33_before . ' try34=' . s:try34_before)

" 在 line 32 前插入语法错误行: `    users`
call append(31, '    users')
" 现在: line 32 = `    users` (语法错误)
"       line 33 = `try users.put(1, ...)` (原 32)
"       line 34 = `try users.put(2, ...)` (原 33)
"       line 35 = `try users.put(3, ...)` (原 34)

call yac#ts_highlights_invalidate()
call yac_test#wait_for({-> !empty(s:get_ts_props(33))}, 5000)

" 三行 try 的高亮应彼此一致（核心断言）
let s:try33_err = get(s:get_prop_at(33, 5), 'type', '')
let s:try34_err = get(s:get_prop_at(34, 5), 'type', '')
let s:try35_err = get(s:get_prop_at(35, 5), 'type', '')

call yac_test#log('INFO', 'With error line: try33=' . s:try33_err
  \ . ' try34=' . s:try34_err . ' try35=' . s:try35_err)

call yac_test#assert_eq(s:try33_err, s:try34_err,
  \ 'With syntax error above, "try" on line 33 and 34 should match')
call yac_test#assert_eq(s:try33_err, s:try35_err,
  \ 'With syntax error above, "try" on line 33 and 35 should match')

" users 标识符高亮也应一致
let s:users33_err = get(s:get_prop_at(33, 9), 'type', '')
let s:users34_err = get(s:get_prop_at(34, 9), 'type', '')
let s:users35_err = get(s:get_prop_at(35, 9), 'type', '')

call yac_test#assert_eq(s:users33_err, s:users34_err,
  \ 'With syntax error above, "users" on line 33 and 34 should match')
call yac_test#assert_eq(s:users33_err, s:users35_err,
  \ 'With syntax error above, "users" on line 33 and 35 should match')

" 验证 try 仍然被识别（没有因为语法错误而丢失高亮）
call yac_test#assert_true(!empty(s:try33_err),
  \ '"try" should still have highlights despite syntax error above')

" ============================================================================
" Test 6: 删除行后 invalidate — 高亮正确
" ============================================================================
call yac_test#log('INFO', 'Test 6: After line deletion + invalidate, highlights correct')

call s:reload_and_wait()

" 记录 line 34 签名
let s:sig34_orig = s:props_signature(34)

" 删除 line 32（第一个 try users.put）
execute '32d'
" 原 line 34 → line 33

call yac#ts_highlights_invalidate()
call yac_test#wait_for({-> !empty(s:get_ts_props(33))}, 5000)

let s:sig33_after_del = s:props_signature(33)
call yac_test#assert_eq(s:sig33_after_del, s:sig34_orig,
  \ 'After deleting line above, shifted line should keep same highlight signature')

" ============================================================================
" Cleanup
" ============================================================================
call yac#ts_highlights_disable()
call yac_test#teardown()
call yac_test#end()
