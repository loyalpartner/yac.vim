" ============================================================================
" E2E Test: Multi-Language — TypeScript (typescript-language-server)
" ============================================================================

call yac_test#begin('multi_language_typescript')
call yac_test#setup()

function! s:lsp_available(cmd) abort
  return executable(a:cmd)
endfunction

" ============================================================================
" Test Suite 2: TypeScript (typescript-language-server)
" ============================================================================
call yac_test#log('INFO', '=== TypeScript Tests ===')

if s:lsp_available('typescript-language-server')
  call yac_test#log('INFO', 'typescript-language-server found')

  new
  setlocal buftype=nofile
  set filetype=typescript

  call setline(1, [
        \ 'interface User {',
        \ '  id: number;',
        \ '  name: string;',
        \ '  email: string;',
        \ '}',
        \ '',
        \ 'class UserService {',
        \ '  private users: User[] = [];',
        \ '',
        \ '  addUser(user: User): void {',
        \ '    this.users.push(user);',
        \ '  }',
        \ '',
        \ '  getUser(id: number): User | undefined {',
        \ '    return this.users.find(u => u.id === id);',
        \ '  }',
        \ '}',
        \ '',
        \ 'const service = new UserService();',
        \ 'service.addUser({ id: 1, name: "Alice", email: "alice@test.com" });',
        \ ])

  call yac_test#wait_lsp_ready(1000)

  " Test 2.1: TypeScript goto definition
  call yac_test#log('INFO', 'Test 2.1: TypeScript goto definition')
  call cursor(10, 20)
  let start_line = line('.')

  YacDefinition
  call yac_test#wait_line_change(start_line, 1000)

  let end_line = line('.')
  call yac_test#log('INFO', 'TypeScript goto: ' . start_line . ' -> ' . end_line)

  " Test 2.2: TypeScript hover
  call yac_test#log('INFO', 'Test 2.2: TypeScript hover')
  call cursor(7, 7)
  call popup_clear()

  YacHover
  call yac_test#wait_popup(1000)

  let popups = popup_list()
  call yac_test#log('INFO', 'TypeScript hover: ' . len(popups) . ' popups')
  call popup_clear()

  bdelete!

else
  call yac_test#skip('TypeScript tests', 'typescript-language-server not installed')
endif

call yac_test#teardown()
call yac_test#end()
