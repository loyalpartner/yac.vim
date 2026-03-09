" ============================================================================
" E2E Test: Multi-Language — Switching, multi-buffer, unsupported
" ============================================================================

call yac_test#begin('multi_language_switching')
call yac_test#setup()

function! s:lsp_available(cmd) abort
  return executable(a:cmd)
endfunction

" ============================================================================
" Test 4: Language switching
" ============================================================================
call yac_test#log('INFO', 'Test 4: Switch between languages')

call yac_test#open_test_file('test_data/src/main.zig', 8000)

call cursor(6, 12)
call yac#hover()
call yac_test#wait_popup(1000)
call yac_test#log('INFO', 'Rust hover works after language switch')
call popup_clear()

" ============================================================================
" Test 5: Multiple language buffers
" ============================================================================
call yac_test#log('INFO', 'Test 5: Multiple language buffers simultaneously')

edit! test_data/src/main.zig
let rust_buf = bufnr('%')

if s:lsp_available('pyright-langserver') || s:lsp_available('pyright')
  new
  setlocal buftype=nofile
  set filetype=python
  call setline(1, ['def hello(): return "world"'])
  let python_buf = bufnr('%')

  call cursor(1, 5)
  call yac#hover()
  call yac_test#wait_popup(1000)
  call yac_test#log('INFO', 'Python hover in multi-buffer')
  call popup_clear()

  execute 'buffer ' . rust_buf
  call cursor(14, 12)
  call yac#hover()
  call yac_test#wait_popup(1000)
  call yac_test#log('INFO', 'Rust hover after buffer switch')
  call popup_clear()

  execute 'bdelete! ' . python_buf
endif

" ============================================================================
" Test 6: Unsupported language handling
" ============================================================================
call yac_test#log('INFO', 'Test 6: Unsupported language graceful handling')

new
setlocal buftype=nofile
set filetype=markdown
call setline(1, ['# Markdown file', '', 'This is not code.'])

call yac#hover()
call yac_test#wait_popup(500)
call yac_test#log('INFO', 'Markdown hover handled gracefully')

let start_line = line('.')
call yac#goto_definition()
call yac_test#wait_line_change(start_line, 500)
call yac_test#log('INFO', 'Markdown goto handled gracefully')

bdelete!

edit! test_data/src/main.zig
call yac_test#teardown()
call yac_test#end()
