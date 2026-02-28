" ============================================================================
" E2E Test: Key Mappings and User Interaction
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('keymaps')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 15000)

" ============================================================================
" Test 1: gd - Goto Definition mapping
" ============================================================================
call yac_test#log('INFO', 'Test 1: gd mapping (Goto Definition)')

let gd_map = maparg('gd', 'n')
call yac_test#assert_true(!empty(gd_map), 'gd mapping should exist')

if !empty(gd_map)
  call cursor(34, 18)
  normal! f.w
  let start_line = line('.')
  normal gd
  call yac_test#wait_line_change(start_line, 5000)
  call yac_test#assert_line_changed(start_line, 'gd should jump to definition')
endif

" ============================================================================
" Test 2: gD - Goto Declaration mapping
" ============================================================================
call yac_test#log('INFO', 'Test 2: gD mapping (Goto Declaration)')

edit! test_data/src/main.zig
let gD_map = maparg('gD', 'n')
call yac_test#assert_true(!empty(gD_map), 'gD mapping should exist')

" ============================================================================
" Test 3: K - Hover mapping
" ============================================================================
call yac_test#log('INFO', 'Test 3: K mapping (Hover)')

edit! test_data/src/main.zig
let K_map = maparg('K', 'n')
call yac_test#assert_true(!empty(K_map), 'K mapping should exist')

if !empty(K_map) && match(K_map, '[Yy]ac\|[Hh]over') >= 0
  call cursor(6, 12)
  call popup_clear()
  normal K
  call yac_test#wait_assert({-> !empty(popup_list())}, 5000,
    \ 'K should open hover popup')
  call popup_clear()
endif

" ============================================================================
" Test 4: gr - References mapping
" ============================================================================
call yac_test#log('INFO', 'Test 4: gr mapping (References)')

let gr_map = maparg('gr', 'n')
call yac_test#assert_true(!empty(gr_map), 'gr mapping should exist')

if !empty(gr_map)
  call cursor(6, 12)
  normal gr
  " References opens picker, not quickfix
  call yac_test#wait_assert({-> yac#picker_is_open()}, 8000,
    \ 'gr should open references picker')
  " Close picker
  call yac#picker_close()
  call yac_test#wait_for({-> !yac#picker_is_open()}, 1000)
  edit! test_data/src/main.zig
endif

" ============================================================================
" Test 5: Leader key mappings exist
" ============================================================================
call yac_test#log('INFO', 'Test 5: Leader key mappings')

let leader = exists('g:mapleader') ? g:mapleader : '\'

for [key, desc] in [
  \ ['rn', 'rename'],
  \ ['ca', 'code action'],
  \ ['fm', 'format'],
  \ ['ih', 'inlay hints toggle'],
  \ ]
  let map_result = maparg(leader . key, 'n')
  call yac_test#assert_true(!empty(map_result),
    \ printf('<leader>%s (%s) mapping should exist', key, desc))
endfor

" ============================================================================
" Test 6: Yac commands exist
" ============================================================================
call yac_test#log('INFO', 'Test 6: Yac commands')

for cmd in ['YacStart', 'YacStop', 'YacDefinition', 'YacHover',
      \ 'YacComplete', 'YacReferences', 'YacInlayHintsToggle',
      \ 'YacRename', 'YacCodeAction', 'YacFormat']
  call yac_test#assert_true(exists(':' . cmd) == 2,
    \ printf(':%s command should exist', cmd))
endfor

" ============================================================================
" Test 7: Tree-sitter navigation mappings
" ============================================================================
call yac_test#log('INFO', 'Test 7: Tree-sitter navigation mappings')

for [key, desc] in [[']f', 'next function'], ['[f', 'prev function'],
      \ [']s', 'next struct'], ['[s', 'prev struct']]
  let map_result = maparg(key, 'n')
  call yac_test#assert_true(!empty(map_result),
    \ printf('%s (%s) mapping should exist', key, desc))
endfor

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
