" ============================================================================
" E2E Test: Multi-Language — Go (gopls)
" ============================================================================

call yac_test#begin('multi_language_go')
call yac_test#setup()

function! s:lsp_available(cmd) abort
  return executable(a:cmd)
endfunction

" ============================================================================
" Test Suite 3: Go (gopls)
" ============================================================================
call yac_test#log('INFO', '=== Go Tests (gopls) ===')

if s:lsp_available('gopls')
  call yac_test#log('INFO', 'gopls found')

  new
  setlocal buftype=nofile
  set filetype=go

  call setline(1, [
        \ 'package main',
        \ '',
        \ 'import "fmt"',
        \ '',
        \ 'type User struct {',
        \ '    ID   int',
        \ '    Name string',
        \ '}',
        \ '',
        \ 'func NewUser(id int, name string) *User {',
        \ '    return &User{ID: id, Name: name}',
        \ '}',
        \ '',
        \ 'func (u *User) Greet() string {',
        \ '    return fmt.Sprintf("Hello, %s", u.Name)',
        \ '}',
        \ '',
        \ 'func main() {',
        \ '    user := NewUser(1, "Alice")',
        \ '    fmt.Println(user.Greet())',
        \ '}',
        \ ])

  call yac_test#wait_lsp_ready(1000)

  " Test 3.1: Go goto definition
  call yac_test#log('INFO', 'Test 3.1: Go goto definition')
  call cursor(19, 12)
  let start_line = line('.')

  call yac#goto_definition()
  call yac_test#wait_line_change(start_line, 1000)

  let end_line = line('.')
  call yac_test#log('INFO', 'Go goto: ' . start_line . ' -> ' . end_line)

  " Test 3.2: Go hover
  call yac_test#log('INFO', 'Test 3.2: Go hover')
  call cursor(5, 6)
  call popup_clear()

  call yac#hover()
  call yac_test#wait_popup(1000)

  let popups = popup_list()
  call yac_test#log('INFO', 'Go hover: ' . len(popups) . ' popups')
  call popup_clear()

  bdelete!

else
  call yac_test#skip('Go tests', 'gopls not installed')
endif

call yac_test#teardown()
call yac_test#end()
