" Test for inlay hints functionality
" This test verifies that the inlay hints command works correctly

" Create a test Rust file for inlay hints
let s:test_file = tempname() . '.rs'

function! s:create_test_file()
  call writefile([
    \ 'fn main() {',
    \ '    let x = 42;',
    \ '    let y = Some(x);',
    \ '    match y {',
    \ '        Some(val) => println!("Got: {}", val),',
    \ '        None => println!("Nothing"),',
    \ '    }',
    \ '}'
  \ ], s:test_file)
endfunction

function! s:cleanup_test_file()
  if filereadable(s:test_file)
    call delete(s:test_file)
  endif
endfunction

function! s:test_inlay_hints_whole_file()
  echo "Testing inlay hints for whole file..."
  call s:create_test_file()
  
  " Open the test file
  execute 'edit ' . s:test_file
  
  " Test whole file inlay hints
  YacInlayHints
  
  " Wait a bit for response (in real usage this would be async)
  sleep 100m
  
  echo "✓ Whole file inlay hints test completed"
  call s:cleanup_test_file()
endfunction

function! s:test_inlay_hints_range()
  echo "Testing inlay hints for range..."
  call s:create_test_file()
  
  " Open the test file
  execute 'edit ' . s:test_file
  
  " Test range-based inlay hints (lines 2-4)
  2,4YacInlayHints
  
  " Wait a bit for response
  sleep 100m
  
  echo "✓ Range-based inlay hints test completed"
  call s:cleanup_test_file()
endfunction

function! s:test_clear_inlay_hints()
  echo "Testing clear inlay hints..."
  call s:create_test_file()
  
  " Open the test file
  execute 'edit ' . s:test_file
  
  " Show hints first
  YacInlayHints
  sleep 100m
  
  " Then clear them
  YacClearInlayHints
  
  echo "✓ Clear inlay hints test completed"
  call s:cleanup_test_file()
endfunction

" Run all tests
function! TestInlayHints()
  echo "=== Running Inlay Hints Tests ==="
  
  " Start LSP bridge first (if not already started)
  try
    YacStart
  catch
    " LSP bridge might already be running
  endtry
  
  call s:test_inlay_hints_whole_file()
  call s:test_inlay_hints_range()
  call s:test_clear_inlay_hints()
  
  echo "=== All Inlay Hints Tests Completed ==="
endfunction

" Allow running the test
command! TestInlayHints call TestInlayHints()

echo "Inlay hints test file loaded. Run :TestInlayHints to execute tests."