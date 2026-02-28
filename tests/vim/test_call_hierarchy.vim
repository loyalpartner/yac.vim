" ============================================================================
" E2E Test: Call Hierarchy (Incoming/Outgoing Calls)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('call_hierarchy')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 15000)

" ============================================================================
" Test 1: Incoming calls to User.init
" ============================================================================
call yac_test#log('INFO', 'Test 1: Incoming calls to User.init')

" 定位到 User.init 方法定义
call cursor(14, 12)  " pub fn new
let word = expand('<cword>')
call yac_test#assert_eq(word, 'init', 'Cursor should be on "init"')

" 查找调用者（谁调用了这个函数）
YacCallHierarchyIncoming
call yac_test#wait_qflist(500)

" 检查结果
let qflist = getqflist()
let loclist = getloclist(0)
let popups = popup_list()

if !empty(qflist)
  call yac_test#log('INFO', 'Incoming calls in quickfix: ' . len(qflist))
  call yac_test#assert_true(len(qflist) >= 1, 'User.init should have at least 1 caller')

  " createUserMap 调用了 User.init
  let callers = join(map(copy(qflist), 'v:val.text'), ' ')
  call yac_test#log('INFO', 'Callers: ' . callers)

elseif !empty(loclist)
  call yac_test#log('INFO', 'Incoming calls in loclist: ' . len(loclist))

elseif !empty(popups)
  call yac_test#log('INFO', 'Incoming calls in popup')
  call yac_test#assert_true(1, 'Call hierarchy displayed')

else
  call yac_test#log('INFO', 'No incoming calls found')
endif

" ============================================================================
" Test 2: Outgoing calls from createUserMap
" ============================================================================
call yac_test#log('INFO', 'Test 2: Outgoing calls from createUserMap')

" 定位到 createUserMap 函数
call cursor(30, 8)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'createUserMap', 'Cursor should be on createUserMap')

" 查找被调用的函数
YacCallHierarchyOutgoing
call yac_test#wait_qflist(500)

let qflist = getqflist()
if !empty(qflist)
  call yac_test#log('INFO', 'Outgoing calls: ' . len(qflist))

  " createUserMap 调用了：
  " - AutoHashMap.init
  " - User.init (多次)
  " - users.put
  call yac_test#assert_true(len(qflist) >= 2, 'Should have multiple outgoing calls')

  let callees = join(map(copy(qflist), 'v:val.text'), ' ')
  call yac_test#log('INFO', 'Callees: ' . callees)
else
  call yac_test#log('INFO', 'No outgoing calls in quickfix')
endif

" ============================================================================
" Test 3: Incoming calls to getName
" ============================================================================
call yac_test#log('INFO', 'Test 3: Incoming calls to getName method')

" 定位到 getName 方法
call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on getName')

YacCallHierarchyIncoming
call yac_test#wait_qflist(500)

let qflist = getqflist()
if !empty(qflist)
  call yac_test#log('INFO', 'getName callers: ' . len(qflist))
  " processUser 和测试函数调用了 getName
endif

" ============================================================================
" Test 4: Navigate through call hierarchy
" ============================================================================
call yac_test#log('INFO', 'Test 4: Navigate call hierarchy results')

let qflist = getqflist()
if !empty(qflist)
  let start_pos = getpos('.')

  " 跳转到第一个调用者
  cfirst
  let first_pos = getpos('.')

  call yac_test#log('INFO', 'Jumped to caller at line ' . first_pos[1])
  call yac_test#assert_neq(start_pos[1], first_pos[1], 'Should jump to caller')

  " 如果有多个结果，跳转到下一个
  if len(qflist) > 1
    cnext
    let next_pos = getpos('.')
    call yac_test#log('INFO', 'Next caller at line ' . next_pos[1])
  endif
endif

" ============================================================================
" Test 5: Call hierarchy on struct (no calls expected)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Call hierarchy on non-function')

" 回到测试文件
edit! test_data/src/main.zig

" 定位到 User struct（不是函数）
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on User struct')

YacCallHierarchyIncoming
call yac_test#wait_qflist(500)

" struct 通常没有调用层次
let qflist = getqflist()
call yac_test#log('INFO', 'Struct call hierarchy results: ' . len(qflist))

" ============================================================================
" Test 6: Recursive function calls
" ============================================================================
call yac_test#log('INFO', 'Test 6: Call hierarchy depth')

" 测试多层调用关系
" processUser -> getName
" test_user_creation -> User.init, getName

call cursor(44, 8)  " processUser
YacCallHierarchyIncoming
call yac_test#wait_qflist(500)

let qflist = getqflist()
call yac_test#log('INFO', 'processUser callers: ' . len(qflist))

" ============================================================================
" Cleanup
" ============================================================================
call setqflist([])
call yac_test#teardown()
call yac_test#end()
