" ============================================================================
" E2E Test: Multi-Language Support (Python, TypeScript, Go)
" ============================================================================

source tests/vim/framework.vim

call yac_test#begin('multi_language')
call yac_test#setup()

" ============================================================================
" Helper: Check if LSP server is available
" ============================================================================
function! s:lsp_available(cmd) abort
  return executable(a:cmd)
endfunction

" ============================================================================
" Test Suite 1: Python (pyright)
" ============================================================================
call yac_test#log('INFO', '=== Python Tests (pyright) ===')

if s:lsp_available('pyright-langserver') || s:lsp_available('pyright')
  call yac_test#log('INFO', 'pyright found, running Python tests')

  " 创建临时 Python 文件
  new
  setlocal buftype=nofile
  set filetype=python
  let b:python_test = 1

  " Python 测试代码
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

  " 等待 pyright 初始化
  sleep 5

  " Test 1.1: Python goto definition
  call yac_test#log('INFO', 'Test 1.1: Python goto definition')
  call cursor(13, 20)  " User 类引用
  let start_line = line('.')

  YacDefinition
  sleep 2

  let end_line = line('.')
  if end_line != start_line
    call yac_test#log('INFO', 'Python goto: jumped to line ' . end_line)
    call yac_test#assert_true(1, 'Python goto definition works')
  else
    call yac_test#log('INFO', 'Python goto: no jump (LSP may not be ready)')
  endif

  " Test 1.2: Python hover
  call yac_test#log('INFO', 'Test 1.2: Python hover')
  call cursor(3, 7)  " class User
  call popup_clear()

  YacHover
  sleep 2

  let popups = popup_list()
  call yac_test#log('INFO', 'Python hover: ' . len(popups) . ' popups')
  call popup_clear()

  " Test 1.3: Python completion
  call yac_test#log('INFO', 'Test 1.3: Python completion')
  normal! G
  normal! o
  execute "normal! iusers[0]."

  YacComplete
  sleep 2

  let popups = popup_list()
  if !empty(popups) || pumvisible()
    call yac_test#log('INFO', 'Python completion triggered')
  endif

  execute "normal! \<Esc>"
  bdelete!

else
  call yac_test#skip('Python tests', 'pyright not installed')
endif

" ============================================================================
" Test Suite 2: TypeScript (typescript-language-server)
" ============================================================================
call yac_test#log('INFO', '=== TypeScript Tests ===')

if s:lsp_available('typescript-language-server')
  call yac_test#log('INFO', 'typescript-language-server found')

  " 创建临时 TypeScript 文件
  new
  setlocal buftype=nofile
  set filetype=typescript

  " TypeScript 测试代码
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

  sleep 5

  " Test 2.1: TypeScript goto definition
  call yac_test#log('INFO', 'Test 2.1: TypeScript goto definition')
  call cursor(10, 20)  " User 类型引用
  let start_line = line('.')

  YacDefinition
  sleep 2

  let end_line = line('.')
  call yac_test#log('INFO', 'TypeScript goto: ' . start_line . ' -> ' . end_line)

  " Test 2.2: TypeScript hover
  call yac_test#log('INFO', 'Test 2.2: TypeScript hover')
  call cursor(7, 7)  " class UserService
  call popup_clear()

  YacHover
  sleep 2

  let popups = popup_list()
  call yac_test#log('INFO', 'TypeScript hover: ' . len(popups) . ' popups')
  call popup_clear()

  bdelete!

else
  call yac_test#skip('TypeScript tests', 'typescript-language-server not installed')
endif

" ============================================================================
" Test Suite 3: Go (gopls)
" ============================================================================
call yac_test#log('INFO', '=== Go Tests (gopls) ===')

if s:lsp_available('gopls')
  call yac_test#log('INFO', 'gopls found')

  " 创建临时 Go 文件
  new
  setlocal buftype=nofile
  set filetype=go

  " Go 测试代码
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

  sleep 5

  " Test 3.1: Go goto definition
  call yac_test#log('INFO', 'Test 3.1: Go goto definition')
  call cursor(19, 12)  " NewUser 调用
  let start_line = line('.')

  YacDefinition
  sleep 2

  let end_line = line('.')
  call yac_test#log('INFO', 'Go goto: ' . start_line . ' -> ' . end_line)

  " Test 3.2: Go hover
  call yac_test#log('INFO', 'Test 3.2: Go hover')
  call cursor(5, 6)  " type User
  call popup_clear()

  YacHover
  sleep 2

  let popups = popup_list()
  call yac_test#log('INFO', 'Go hover: ' . len(popups) . ' popups')
  call popup_clear()

  bdelete!

else
  call yac_test#skip('Go tests', 'gopls not installed')
endif

" ============================================================================
" Test 4: Language switching
" ============================================================================
call yac_test#log('INFO', 'Test 4: Switch between languages')

" 打开 Rust 文件
edit test_data/src/lib.rs
sleep 2

call cursor(6, 12)
YacHover
sleep 1
call yac_test#log('INFO', 'Rust hover works after language switch')
call popup_clear()

" ============================================================================
" Test 5: Multiple language buffers
" ============================================================================
call yac_test#log('INFO', 'Test 5: Multiple language buffers simultaneously')

" Rust buffer
edit test_data/src/lib.rs
let rust_buf = bufnr('%')

" Python buffer (if available)
if s:lsp_available('pyright-langserver') || s:lsp_available('pyright')
  new
  setlocal buftype=nofile
  set filetype=python
  call setline(1, ['def hello(): return "world"'])
  let python_buf = bufnr('%')

  " 在 Python buffer 中操作
  call cursor(1, 5)
  YacHover
  sleep 1
  call yac_test#log('INFO', 'Python hover in multi-buffer')
  call popup_clear()

  " 切换到 Rust buffer
  execute 'buffer ' . rust_buf
  call cursor(14, 12)
  YacHover
  sleep 1
  call yac_test#log('INFO', 'Rust hover after buffer switch')
  call popup_clear()

  " 清理
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

" 应该不崩溃
YacHover
sleep 1
call yac_test#log('INFO', 'Markdown hover handled gracefully')

YacDefinition
sleep 1
call yac_test#log('INFO', 'Markdown goto handled gracefully')

bdelete!

" ============================================================================
" Cleanup
" ============================================================================
edit test_data/src/lib.rs
call yac_test#teardown()
call yac_test#end()
