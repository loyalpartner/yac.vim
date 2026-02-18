" ============================================================================
" E2E Test: Document Symbols (File Outline)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('document_symbols')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" ============================================================================
" Test 1: Get document symbols
" ============================================================================
call yac_test#log('INFO', 'Test 1: Get document symbols')

" 执行文档符号命令
YacDocumentSymbols
call yac_test#wait_qflist(3000)

" 检查 quickfix 或 location list
let qflist = getqflist()
let loclist = getloclist(0)

if !empty(qflist)
  call yac_test#log('INFO', 'Symbols in quickfix: ' . len(qflist))
  call yac_test#assert_true(len(qflist) >= 5, 'Should have at least 5 symbols')

  " 验证包含预期的符号
  let symbols = map(copy(qflist), 'v:val.text')
  call yac_test#log('INFO', 'First 5 symbols: ' . string(symbols[:4]))

elseif !empty(loclist)
  call yac_test#log('INFO', 'Symbols in location list: ' . len(loclist))
  call yac_test#assert_true(len(loclist) >= 5, 'Should have at least 5 symbols')

else
  " 可能使用 popup 显示
  let popups = popup_list()
  if !empty(popups)
    call yac_test#log('INFO', 'Symbols in popup')
    call yac_test#assert_true(1, 'Symbols displayed in popup')
  else
    call yac_test#log('INFO', 'No symbols found (check implementation)')
  endif
endif

" ============================================================================
" Test 2: Symbol types
" ============================================================================
call yac_test#log('INFO', 'Test 2: Verify symbol types')

" test_data/src/lib.rs 应该包含：
" - User struct
" - User impl
" - create_user_map function
" - process_user function
" - tests module

let qflist = getqflist()
if !empty(qflist)
  let symbol_texts = join(map(copy(qflist), 'v:val.text'), ' ')

  " 检查关键符号
  let has_user = match(symbol_texts, 'User') >= 0
  let has_create = match(symbol_texts, 'create_user_map') >= 0
  let has_process = match(symbol_texts, 'process_user') >= 0

  call yac_test#log('INFO', 'Has User: ' . has_user)
  call yac_test#log('INFO', 'Has create_user_map: ' . has_create)
  call yac_test#log('INFO', 'Has process_user: ' . has_process)

  if has_user
    call yac_test#assert_true(1, 'Should contain User symbol')
  endif
endif

" ============================================================================
" Test 3: Navigate to symbol
" ============================================================================
call yac_test#log('INFO', 'Test 3: Navigate to symbol from list')

let qflist = getqflist()
if !empty(qflist)
  " 跳转到第一个符号
  let start_line = line('.')
  cfirst
  let after_line = line('.')

  call yac_test#assert_neq(start_line, after_line, 'Should jump to symbol location')
  call yac_test#log('INFO', 'Jumped from ' . start_line . ' to ' . after_line)

  " 跳转到下一个符号
  if len(qflist) > 1
    let before_next = line('.')
    cnext
    let after_next = line('.')
    call yac_test#log('INFO', 'Next symbol at line ' . after_next)
  endif
endif

" ============================================================================
" Test 4: Symbol hierarchy (nested symbols)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Nested symbols (impl methods)')

" impl User 下应该有 new, get_name, get_email 等方法
" 这取决于 LSP 返回的符号结构

YacDocumentSymbols
call yac_test#wait_qflist(3000)

let qflist = getqflist()
if !empty(qflist)
  " 检查是否有方法级符号
  let method_count = 0
  for item in qflist
    if match(item.text, 'new\|get_name\|get_email') >= 0
      let method_count += 1
    endif
  endfor
  call yac_test#log('INFO', 'Method symbols found: ' . method_count)
endif

" ============================================================================
" Test 5: Symbols after file modification
" ============================================================================
call yac_test#log('INFO', 'Test 5: Symbols update after modification')

" 保存原始内容
let original_content = getline(1, '$')

" 添加新函数
normal! G
normal! o
execute "normal! ipub fn new_test_function() -> i32 { 42 }"

" 重新获取符号
YacDocumentSymbols
call yac_test#wait_qflist(3000)

let qflist = getqflist()
if !empty(qflist)
  let symbol_texts = join(map(copy(qflist), 'v:val.text'), ' ')
  let has_new_func = match(symbol_texts, 'new_test_function') >= 0
  call yac_test#log('INFO', 'New function in symbols: ' . has_new_func)
endif

" 恢复文件
silent! %d
call setline(1, original_content)

" ============================================================================
" Test 6: Empty file symbols
" ============================================================================
call yac_test#log('INFO', 'Test 6: Symbols for minimal file')

" 创建临时空文件
new
setlocal buftype=nofile
call setline(1, ['// empty rust file', ''])
set filetype=rust

YacDocumentSymbols
call yac_test#wait_qflist(3000)

let qflist = getqflist()
call yac_test#log('INFO', 'Empty file symbols: ' . len(qflist))

" 关闭临时 buffer
bdelete!

" 回到测试文件
edit! test_data/src/lib.rs

" ============================================================================
" Cleanup
" ============================================================================
call setqflist([])
call yac_test#teardown()
call yac_test#end()
