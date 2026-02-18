" ============================================================================
" E2E Test: Key Mappings and User Interaction
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('keymaps')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" ============================================================================
" Test 1: gd - Goto Definition mapping
" ============================================================================
call yac_test#log('INFO', 'Test 1: gd mapping (Goto Definition)')

" 检查映射是否存在
let gd_map = maparg('gd', 'n')
call yac_test#log('INFO', 'gd mapping: ' . gd_map)

if !empty(gd_map)
  call yac_test#assert_true(1, 'gd mapping exists')

  " 测试映射功能
  call cursor(34, 18)  " User::new 调用
  normal! f:w  " 移到 new
  let start_line = line('.')

  " 使用映射
  normal gd
  call yac_test#wait_line_change(start_line, 3000)

  let end_line = line('.')
  call yac_test#log('INFO', 'gd jumped from ' . start_line . ' to ' . end_line)
else
  call yac_test#skip('gd mapping', 'Not configured')
endif

" ============================================================================
" Test 2: gD - Goto Declaration mapping
" ============================================================================
call yac_test#log('INFO', 'Test 2: gD mapping (Goto Declaration)')

edit! test_data/src/lib.rs
let gD_map = maparg('gD', 'n')
call yac_test#log('INFO', 'gD mapping: ' . gD_map)

if !empty(gD_map)
  call cursor(34, 18)
  normal! f:w
  let start_line = line('.')

  normal gD
  call yac_test#wait_line_change(start_line, 3000)

  let end_line = line('.')
  call yac_test#log('INFO', 'gD jumped from ' . start_line . ' to ' . end_line)
else
  call yac_test#skip('gD mapping', 'Not configured')
endif

" ============================================================================
" Test 3: K - Hover mapping
" ============================================================================
call yac_test#log('INFO', 'Test 3: K mapping (Hover)')

edit! test_data/src/lib.rs
let K_map = maparg('K', 'n')
call yac_test#log('INFO', 'K mapping: ' . K_map)

if !empty(K_map) && match(K_map, '[Yy]ac\|[Hh]over') >= 0
  call cursor(6, 12)  " User struct
  call popup_clear()

  normal K
  call yac_test#wait_popup(3000)

  let popups = popup_list()
  call yac_test#log('INFO', 'K produced ' . len(popups) . ' popups')
  call popup_clear()
else
  call yac_test#skip('K mapping', 'Not configured for YAC')
endif

" ============================================================================
" Test 4: gr - References mapping
" ============================================================================
call yac_test#log('INFO', 'Test 4: gr mapping (References)')

let gr_map = maparg('gr', 'n')
call yac_test#log('INFO', 'gr mapping: ' . gr_map)

if !empty(gr_map)
  call cursor(6, 12)  " User struct
  call setqflist([])

  normal gr
  call yac_test#wait_qflist(3000)

  let qflist = getqflist()
  call yac_test#log('INFO', 'gr found ' . len(qflist) . ' references')
else
  call yac_test#skip('gr mapping', 'Not configured')
endif

" ============================================================================
" Test 5: Completion key navigation
" ============================================================================
call yac_test#log('INFO', 'Test 5: Completion navigation keys')

" 触发补全
normal! G
normal! o
execute "normal! iUser::"
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

" 测试 Ctrl-N (下一项)
if pumvisible() || !empty(popup_list())
  call yac_test#log('INFO', 'Completion menu visible')

  " Ctrl-N 选择下一项
  execute "normal! \<C-n>"
  call yac_test#log('INFO', 'Ctrl-N pressed')

  " Ctrl-P 选择上一项
  execute "normal! \<C-p>"
  call yac_test#log('INFO', 'Ctrl-P pressed')

  " Escape 取消
  execute "normal! \<Esc>"

  let popups_after = popup_list()
  call yac_test#log('INFO', 'After Esc: ' . len(popups_after) . ' popups')
else
  call yac_test#log('INFO', 'Completion not visible for key test')
endif

" 清理
normal! u

" ============================================================================
" Test 6: Tab/Enter completion confirm
" ============================================================================
call yac_test#log('INFO', 'Test 6: Completion confirm keys')

let original = getline(1, '$')

normal! G
normal! o
execute "normal! ilet user = User::n"
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

if pumvisible() || !empty(popup_list())
  " Tab 或 Enter 确认选择
  " 注意：这取决于配置
  call yac_test#log('INFO', 'Testing completion confirm')

  " 尝试 Tab
  call feedkeys("\<Tab>", 'x')

  let line_content = getline('.')
  call yac_test#log('INFO', 'After Tab: ' . line_content)
endif

" 恢复
execute "normal! \<Esc>"
silent! %d
call setline(1, original)

" ============================================================================
" Test 7: Leader key mappings
" ============================================================================
call yac_test#log('INFO', 'Test 7: Leader key mappings')

" 检查常见的 leader 映射
let leader = exists('g:mapleader') ? g:mapleader : '\'

" 常见的 LSP leader 映射
for mapping in ['ca', 'rn', 'f', 'D']
  let map_key = leader . mapping
  let map_result = maparg(map_key, 'n')
  if !empty(map_result)
    call yac_test#log('INFO', 'Leader+' . mapping . ' -> ' . map_result)
  endif
endfor

" ============================================================================
" Test 8: Diagnostic navigation
" ============================================================================
call yac_test#log('INFO', 'Test 8: Diagnostic navigation keys')

" 常见的诊断导航键
let diag_next = maparg(']d', 'n')
let diag_prev = maparg('[d', 'n')

call yac_test#log('INFO', ']d mapping: ' . diag_next)
call yac_test#log('INFO', '[d mapping: ' . diag_prev)

" ============================================================================
" Test 9: Mouse interaction (if supported)
" ============================================================================
call yac_test#log('INFO', 'Test 9: Mouse hover (if enabled)')

" 检查是否启用了鼠标 hover
if exists('g:yac_enable_mouse_hover') && g:yac_enable_mouse_hover
  call yac_test#log('INFO', 'Mouse hover is enabled')
else
  call yac_test#log('INFO', 'Mouse hover not enabled (expected)')
endif

" ============================================================================
" Test 10: Insert mode mappings
" ============================================================================
call yac_test#log('INFO', 'Test 10: Insert mode completion trigger')

" 检查插入模式下的补全触发
let dot_imap = maparg('.', 'i')
let colon_imap = maparg(':', 'i')

call yac_test#log('INFO', 'Dot insert map: ' . (empty(dot_imap) ? 'none' : 'configured'))
call yac_test#log('INFO', 'Colon insert map: ' . (empty(colon_imap) ? 'none' : 'configured'))

" ============================================================================
" Test 11: Popup/Float window interaction
" ============================================================================
call yac_test#log('INFO', 'Test 11: Popup window keys')

edit! test_data/src/lib.rs
call cursor(6, 12)

YacHover
call yac_test#wait_popup(3000)

let popups = popup_list()
if !empty(popups)
  " 测试关闭 popup
  " 通常 Esc 或移动光标会关闭
  execute "normal! j"
  call yac_test#wait_for({-> empty(popup_list())}, 3000)

  let popups_after_move = popup_list()
  call yac_test#log('INFO', 'Popups after cursor move: ' . len(popups_after_move))
endif

call popup_clear()

" ============================================================================
" Test 12: Command-line completion
" ============================================================================
call yac_test#log('INFO', 'Test 12: Yac command completion')

" 测试命令补全
" :Yac<Tab> 应该显示所有 Yac 命令
call yac_test#log('INFO', 'Yac commands available:')
for cmd in ['YacStart', 'YacStop', 'YacDefinition', 'YacHover', 'YacComplete', 'YacReferences']
  if exists(':' . cmd)
    call yac_test#log('INFO', '  :' . cmd . ' exists')
  endif
endfor

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
