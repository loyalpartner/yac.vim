" Comprehensive auto-import test script
" Usage: vim -u vimrc -c 'source test_auto_import_comprehensive.vim'

echo "=== YAC Auto-Import Test ==="

" Enable debug mode
let g:lsp_bridge_debug = 1

" Create test directory and file
silent! call mkdir('/tmp/yac_test', 'p')
edit /tmp/yac_test/test.rs

" Clear any existing content
normal! ggdG

" Insert test content
call setline(1, [
  \ 'fn main() {',
  \ '    // Test 1: HashMap auto-import',
  \ '    let map1 = HashMap::new();',
  \ '    ',
  \ '    // Test 2: BTreeMap auto-import', 
  \ '    let map2 = BTreeMap::new();',
  \ '    ',
  \ '    // Test 3: VecDeque auto-import',
  \ '    let deque = VecDeque::new();',
  \ '}',
  \ ''
  \ ])

" Start LSP bridge
YacStart

echo "Test file created at /tmp/yac_test/test.rs"
echo "LSP bridge started"
echo ""
echo "Manual testing steps:"
echo "1. Position cursor after 'HashMap' on line 3"
echo "2. Delete 'HashMap' and type it again to trigger completion"
echo "3. Select HashMap completion - should auto-import std::collections::HashMap"
echo "4. Check debug messages for resolve flow"
echo ""
echo "Expected debug output sequence:"
echo "- YacDebug[INSERT]: Inserting completion item"
echo "- YacDebug[RESOLVE]: Requesting resolve for item"
echo "- YacDebug[RECV]: completion resolve response"
echo "- YacDebug[AUTO-IMPORT]: Applying N additional text edits"
echo "- Auto-imported N items"