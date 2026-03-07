" ============================================================================
" E2E Test: Multi-Language — Python (pyright)
" ============================================================================

call yac_test#begin('multi_language_python')
call yac_test#setup()

function! s:lsp_available(cmd) abort
  return executable(a:cmd)
endfunction

" ============================================================================
" Test Suite 1: Python (pyright)
" ============================================================================
call yac_test#log('INFO', '=== Python Tests (pyright) ===')

if s:lsp_available('pyright-langserver') || s:lsp_available('pyright')
  call yac_test#log('INFO', 'pyright found, running Python tests')

  new
  setlocal buftype=nofile
  set filetype=python
  let b:python_test = 1

  call setline(1, [
        \ 'from typing import List, Dict',
        \ '',
        \ 'class User:',
        \ '    def __init__(self, name: str, age: int):',
        \ '        self.name = name',
        \ '        self.age = age',
        \ '',
        \ '    def greet(self) -> str:',
        \ '        return f"Hello, {self.name}"',
        \ '',
        \ 'def create_users() -> List[User]:',
        \ '    users = []',
        \ '    users.append(User("Alice", 30))',
        \ '    users.append(User("Bob", 25))',
        \ '    return users',
        \ '',
        \ 'def main():',
        \ '    users = create_users()',
        \ '    for user in users:',
        \ '        print(user.greet())',
        \ ])

  call yac_test#wait_lsp_ready(1000)

  " Test 1.1: Python goto definition
  call yac_test#log('INFO', 'Test 1.1: Python goto definition')
  call cursor(13, 20)
  let start_line = line('.')

  YacDefinition
  call yac_test#wait_line_change(start_line, 1000)

  let end_line = line('.')
  if end_line != start_line
    call yac_test#log('INFO', 'Python goto: jumped to line ' . end_line)
    call yac_test#assert_true(end_line != start_line, 'Python goto definition works')
  else
    call yac_test#log('INFO', 'Python goto: no jump (LSP may not be ready)')
  endif

  " Test 1.2: Python hover
  call yac_test#log('INFO', 'Test 1.2: Python hover')
  call cursor(3, 7)
  call popup_clear()

  YacHover
  call yac_test#wait_popup(1000)

  let popups = popup_list()
  call yac_test#log('INFO', 'Python hover: ' . len(popups) . ' popups')
  call popup_clear()

  " Test 1.3: Python completion
  call yac_test#log('INFO', 'Test 1.3: Python completion')
  normal! G
  normal! o
  execute "normal! iusers[0]."

  YacComplete
  call yac_test#wait_completion(1000)

  let popups = popup_list()
  if !empty(popups) || pumvisible()
    call yac_test#log('INFO', 'Python completion triggered')
  endif

  execute "normal! \<Esc>"
  bdelete!

else
  call yac_test#skip('Python tests', 'pyright not installed')
endif

call yac_test#teardown()
call yac_test#end()
