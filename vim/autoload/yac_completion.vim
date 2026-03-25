" yac_completion.vim — Completion module (state, trigger, filter, insert)
"
" Dependencies on yac.vim:
"   yac#_request(method, params, callback)  — send daemon request
"   yac#_debug_log(msg)                     — debug logging
"   yac#_at_trigger_char()                             — check trigger char
"   yac#_get_current_word_prefix()                     — word prefix at cursor
"   yac#_in_string_or_comment()                        — syntax check
"   yac#_flush_did_change()                            — flush pending didChange
"   yac#_cursor_lsp_col()                              — LSP column
"
" Rendering is delegated to yac_completion_render.vim

" === Highlight Groups ===

" 补全项类型高亮组 — link 到 tree-sitter 主题，跟随 colorscheme
hi def link YacCompletionFunction  YacTsFunction
hi def link YacCompletionVariable  YacTsVariable
hi def link YacCompletionStruct    YacTsType
hi def link YacCompletionKeyword   YacTsKeyword
hi def link YacCompletionModule    YacTsModule

" 补全项 detail 灰色高亮
if !hlexists('YacCompletionDetail')
  highlight YacCompletionDetail guifg=#6a6a6a ctermfg=242
endif

" 补全弹窗高亮组 — link 到通用 Yac/Vim 组，跟随 colorscheme
hi def link YacCompletionNormal  YacPickerNormal
hi def link YacCompletionSelect  PmenuSel

" 定义补全匹配字符的高亮组
if !hlexists('YacBridgeMatchChar')
  highlight YacBridgeMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

" === Constants ===

" LSP CompletionItemKind: 数字 → 字符串
let s:lsp_kind_map = {
  \ 1: 'Text', 2: 'Method', 3: 'Function', 4: 'Constructor',
  \ 5: 'Field', 6: 'Variable', 7: 'Class', 8: 'Interface',
  \ 9: 'Module', 10: 'Property', 11: 'Unit', 12: 'Value',
  \ 13: 'Enum', 14: 'Keyword', 15: 'Snippet', 16: 'Color',
  \ 17: 'File', 18: 'Reference', 19: 'Folder', 20: 'EnumMember',
  \ 21: 'Constant', 22: 'Struct', 23: 'Event', 24: 'Operator',
  \ 25: 'TypeParameter'
  \ }

" 需要自动加括号的补全项类型
let s:callable_kinds = {'Function': 1, 'Method': 1, 'Constructor': 1}

" === State ===

let s:completion = {}
let s:completion.popup_id = -1
let s:completion.doc_popup_id = -1
let s:completion.items = []
let s:completion.original_items = []
let s:completion.selected = 0
let s:completion.mappings_installed = 0
let s:completion.saved_mappings = {}
let s:completion.trigger_col = 0
let s:completion.suppress_until = 0
let s:completion.timer_id = -1
let s:completion.bg_timer_id = -1
let s:completion.seq = 0
let s:completion.doc_timer_id = -1
let s:completion.cache = []
let s:completion.cache_file = ''
let s:completion.cache_line = -1

" BS mapping state
let s:saved_bs_map = {}

" === Public API ===

function! yac_completion#complete() abort
  call yac#_flush_did_change()

  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if !yac#_at_trigger_char()
      call s:filter_completions()
      return
    endif
    call s:close_completion_popup()
  endif

  " 即时弹出：缓存 → buffer words → 等 LSP
  if s:completion.popup_id == -1 && !yac#_at_trigger_char()
    let l:instant_items = []
    if !empty(s:completion.cache) && s:completion.cache_file ==# expand('%:p')
      let l:instant_items = s:completion.cache
    else
      let l:instant_items = s:collect_buffer_words()
    endif
    if !empty(l:instant_items)
      let s:completion.trigger_col = col('.') - len(yac#_get_current_word_prefix())
      let s:completion.original_items = l:instant_items
      call s:filter_completions()
    endif
  endif

  " 递增序列号，丢弃旧请求的响应
  let s:completion.seq += 1
  let l:seq = s:completion.seq

  let l:lsp_col = yac#_cursor_lsp_col()

  call yac#_request('completion', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': l:lsp_col
    \ }, {ch, resp -> s:handle_completion_response(ch, resp, l:seq)})
endfunction

" 自动补全触发检查
function! yac_completion#auto_complete_trigger() abort
  if !get(g:, 'yac_auto_complete', 1) || !get(b:, 'yac_lsp_supported', 0)
    return
  endif

  " 补全插入后短暂抑制，避免 feedkeys 触发的 TextChangedI 重新弹出菜单
  if type(s:completion.suppress_until) != v:t_number
    let elapsed = reltimefloat(reltime(s:completion.suppress_until))
    let s:completion.suppress_until = 0
    if elapsed < 0.3
      return
    endif
  endif

  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤 + 后台 racing
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if yac#_at_trigger_char()
      call s:close_completion_popup()
      " 触发字符继续走下面的完整请求流程
    else
      let l:line = getline('.')
      let l:cc = yac#_cursor_lsp_col() - 1
      if l:cc >= 0 && l:line[l:cc] =~ '\w'
        " 即时本地过滤
        call s:filter_completions()
        " 同时安排后台 LSP 请求（200ms debounce），带来更精确的结果
        call s:schedule_background_completion()
        return
      else
        call s:close_completion_popup()
      endif
    endif
  endif

  if mode() != 'i'
    return
  endif

  if yac#_in_string_or_comment()
    return
  endif

  " 前缀不够长且不在触发字符后 → 跳过
  let prefix = yac#_get_current_word_prefix()
  let l:is_trigger = yac#_at_trigger_char()
  if len(prefix) < get(g:, 'yac_auto_complete_min_chars', 1) && !l:is_trigger
    return
  endif

  " 触发字符 → 立即 flush did_change 并直接请求，跳过 timer
  if l:is_trigger
    " A pending timer from earlier keystrokes (e.g. 's','t','d' before '.')
    " would fire after our request and call complete() again, bumping seq
    " and making our response stale.
    if s:completion.timer_id != -1
      call timer_stop(s:completion.timer_id)
      let s:completion.timer_id = -1
    endif
    call yac#_flush_did_change()
    call yac_completion#complete()
    return
  endif

  " Timer 已在等待 → 不重置，让它尽快触发（避免快速输入时不断重启 timer）
  if s:completion.timer_id != -1
    return
  endif

  " 首次触发用 timer_start(0)：下一个事件循环即刻发出请求
  let s:completion.timer_id = timer_start(0, 'yac_completion#delayed_complete')
endfunction

" 延迟补全触发
function! yac_completion#delayed_complete(timer_id) abort
  let s:completion.timer_id = -1

  " 确保仍在插入模式
  if mode() != 'i'
    return
  endif

  " 触发补全
  call yac_completion#complete()
endfunction

" 公开接口：关闭补全弹窗（供 InsertLeave autocmd 调用）
function! yac_completion#close() abort
  call s:close_completion_popup()
endfunction

" Check if completion popup is visible (used by signature module)
function! yac_completion#popup_visible() abort
  return s:completion.popup_id != -1
endfunction

" === Internal State Accessor (for render/test modules) ===

" Returns a reference to s:completion dict (VimScript dict reference semantics)
function! yac_completion#_get_state() abort
  return s:completion
endfunction

" === BS Mapping ===

function! yac_completion#install_bs_mapping() abort
  let s:saved_bs_map = maparg('<BS>', 'i', 0, 1)
  inoremap <silent><expr> <BS> yac_completion#bs_key()
endfunction

function! yac_completion#uninstall_bs_mapping() abort
  if !empty(s:saved_bs_map)
    call mapset('i', 0, s:saved_bs_map)
    let s:saved_bs_map = {}
  else
    silent! iunmap <BS>
  endif
endfunction

function! yac_completion#bs_key() abort
  if s:completion.popup_id != -1
    let l:col = col('.')
    if l:col <= 1
      call s:close_completion_popup()
      return s:invoke_original_bs()
    endif
    " Defer BS to timer (can't call setline in <expr>)
    call timer_start(0, {-> s:deferred_completion_bs()})
    return ''
  endif
  return s:invoke_original_bs()
endfunction

" === Test Helpers (state inspection & injection) ===

function! yac_completion#get_state() abort
  return {
    \ 'popup_id': s:completion.popup_id,
    \ 'items': s:completion.items,
    \ 'selected': s:completion.selected,
    \ 'suppress_until': s:completion.suppress_until,
    \ }
endfunction

function! yac_completion#test_inject_response(items) abort
  call s:show_completion_popup(a:items)
endfunction

function! yac_completion#test_inject_async_response(items) abort
  call s:handle_completion_response(v:null, {'items': a:items})
endfunction

function! yac_completion#test_inject_response_with_seq(items, seq) abort
  call s:handle_completion_response(v:null, {'items': a:items}, a:seq)
endfunction

function! yac_completion#test_get_seq() abort
  return s:completion.seq
endfunction

function! yac_completion#test_bump_seq() abort
  let s:completion.seq += 1
  return s:completion.seq
endfunction

function! yac_completion#get_popup_options() abort
  if s:completion.popup_id == -1
    return {}
  endif
  return popup_getoptions(s:completion.popup_id)
endfunction

" === Internal: Kind Normalization ===

function! yac_completion#_normalize_kind(kind) abort
  if type(a:kind) == v:t_number
    return get(s:lsp_kind_map, a:kind, 'Text')
  endif
  return a:kind
endfunction

" === Internal: Keyboard Filter ===

" Public (prefixed _) so render module can pass it as popup filter funcref
function! yac_completion#_filter(winid, key) abort
  " popup 已被代码关闭但 Vim 仍路由按键 — 透传
  if s:completion.popup_id == -1
    return 0
  endif
  let nr = char2nr(a:key)

  " C-n / Down / Tab: 下一项
  if nr == 14 || a:key == "\<Down>"
    call s:move_completion_selection(1)
    return 1
  endif

  " C-p / Up / S-Tab: 上一项
  if nr == 16 || a:key == "\<Up>"
    call s:move_completion_selection(-1)
    return 1
  endif

  " CR: 接受补全
  if a:key == "\<CR>"
    if !empty(s:completion.items)
      call s:insert_completion(s:completion.items[s:completion.selected])
    endif
    return 1
  endif

  " Tab: accept completion item
  if a:key == "\<Tab>"
    if !empty(s:completion.items)
      call s:insert_completion(s:completion.items[s:completion.selected])
    endif
    return 1
  endif

  " Esc / C-e: 关闭补全
  if a:key == "\<Esc>" || nr == 5
    call s:close_completion_popup()
    let s:completion.suppress_until = reltime()
    " Esc 还要退出 insert 模式
    if a:key == "\<Esc>"
      call feedkeys("\<Esc>", 'nt')
    endif
    return 1
  endif

  " BS / C-h: 手动删字符 + 重新过滤
  if a:key == "\<BS>" || nr == 8
    let l:col = col('.')
    if l:col <= 1
      call s:close_completion_popup()
      return 0
    endif
    " 删除光标前一个字符（支持多字节）
    let l:line = getline('.')
    let l:before = strpart(l:line, 0, l:col - 1)
    let l:char = matchstr(l:before, '.$')
    let l:new_before = strpart(l:before, 0, strlen(l:before) - strlen(l:char))
    let l:after = strpart(l:line, l:col - 1)
    call setline('.', l:new_before . l:after)
    call cursor(line('.'), strlen(l:new_before) + 1)
    " 通知 LSP 文本变化
    call yac#did_change()
    " 重新过滤补全列表
    call s:filter_completions()
    return 1
  endif

  " 其他按键：透传给 insert 模式
  return 0
endfunction

" === Internal: Background Completion ===

function! s:schedule_background_completion() abort
  if s:completion.bg_timer_id != -1
    call timer_stop(s:completion.bg_timer_id)
  endif
  let s:completion.bg_timer_id = timer_start(200, 's:bg_completion_fire')
endfunction

function! s:bg_completion_fire(timer_id) abort
  let s:completion.bg_timer_id = -1
  if mode() != 'i' || s:completion.popup_id == -1
    return
  endif
  call yac#_flush_did_change()
  let s:completion.seq += 1
  let l:seq = s:completion.seq
  let l:lsp_col = yac#_cursor_lsp_col()
  call yac#_request('completion', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': l:lsp_col
    \ }, {ch, resp -> s:handle_completion_response(ch, resp, l:seq)})
endfunction

" === Internal: Response Handling ===

function! s:handle_completion_response(channel, response, ...) abort
  call yac#_debug_log(printf('[RECV]: completion response: %s', string(a:response)))

  " 序列号不匹配 → 丢弃过时响应
  if a:0 > 0 && a:1 != s:completion.seq
    call yac#_debug_log(printf('[SKIP]: stale completion response (seq %d, current %d)', a:1, s:completion.seq))
    return
  endif

  " suppress 窗口内 → 忽略（用户刚关闭/接受补全）
  if type(s:completion.suppress_until) != v:t_number
    if reltimefloat(reltime(s:completion.suppress_until)) < 0.3
      return
    endif
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#_debug_log('[yac] Completion error: ' . string(a:response.error))
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'items') && !empty(a:response.items)
    call s:show_completion_popup(a:response.items)
  else
    " Close completion popup when no completions available
    call s:close_completion_popup()
  endif
endfunction

" === Internal: Buffer Words ===

function! s:collect_buffer_words() abort
  let l:cur_word = yac#_get_current_word_prefix()
  if empty(l:cur_word) | return [] | endif

  " 扫描可见区域 ± 50 行
  let l:top = max([1, line('w0') - 50])
  let l:bot = min([line('$'), line('w$') + 50])
  let l:lines = getline(l:top, l:bot)

  " 提取所有 >= 3 字符的单词，去重
  let l:seen = {}
  let l:items = []
  for l:line in l:lines
    for l:word in split(l:line, '\W\+')
      if len(l:word) >= 3 && !has_key(l:seen, l:word) && l:word !=# l:cur_word
        let l:seen[l:word] = 1
        call add(l:items, {'label': l:word, 'kind': 'Text'})
      endif
    endfor
  endfor
  return l:items
endfunction

" === Internal: Popup Show ===

function! s:show_completion_popup(items) abort
  if s:completion.popup_id == -1
    " 没有现有 popup → 正常创建
    let s:completion.trigger_col = col('.') - len(yac#_get_current_word_prefix())
    let s:completion.selected = 0
  endif
  " popup 已存在（LSP 异步更新）→ 保留 selected 位置，只更新 items

  " 存储原始补全项目
  let s:completion.original_items = a:items

  " 应用当前前缀的过滤（会复用或创建 popup）
  call s:filter_completions()
endfunction

" === Internal: Filter ===

function! s:filter_completions() abort
  let current_prefix = yac#_get_current_word_prefix()

  if empty(current_prefix)
    " 空前缀：保留全部（LSP 已按相关性排序）
    for item in s:completion.original_items
      let item._match_positions = []
    endfor
    let s:completion.items = s:completion.original_items
  else
    " matchfuzzypos: C 实现的 fuzzy match + sort + 位置提取
    let [matched, positions, scores] = matchfuzzypos(
      \ s:completion.original_items, current_prefix, {'key': 'label'})
    for i in range(len(matched))
      let matched[i]._match_positions = positions[i]
    endfor
    let s:completion.items = matched
  endif

  " clamp selected 防止越界
  if s:completion.selected >= len(s:completion.items)
    let s:completion.selected = max([0, len(s:completion.items) - 1])
  endif

  " 0 结果时自动关闭弹窗
  if empty(s:completion.items)
    call s:close_completion_popup()
    return
  endif

  call yac_completion_render#render(s:completion)
endfunction

" === Internal: Navigation ===

function! s:move_completion_selection(direction) abort
  let new_idx = s:completion.selected + a:direction

  " 边界 clamp
  if new_idx < 0 || new_idx >= len(s:completion.items)
    return
  endif

  let s:completion.selected = new_idx
  call yac_completion_render#highlight_selected(s:completion)

  " debounce 文档请求
  if s:completion.doc_timer_id != -1
    call timer_stop(s:completion.doc_timer_id)
  endif
  let s:completion.doc_timer_id = timer_start(100, {-> yac_completion_render#show_doc(yac_completion#_get_state())})
endfunction

" === Internal: Insert & Close ===

function! s:insert_completion(item) abort
  call s:close_completion_popup()

  " 抑制接下来的自动补全触发
  let s:completion.suppress_until = reltime()

  " 确保在插入模式下
  if mode() !=# 'i'
    return
  endif

  " 优先使用 insertText（LSP 字段），其次 label
  let insert_text = get(a:item, 'insertText', a:item.label)
  if empty(insert_text)
    let insert_text = a:item.label
  endif

  " 使用 setline() 直接替换文本（正确处理多字节字符）
  let line = getline('.')
  let cursor_byte_col = col('.') - 1

  " 函数/方法自动加括号
  let kind_str = yac_completion#_normalize_kind(get(a:item, 'kind', ''))
  let add_parens = has_key(s:callable_kinds, kind_str)
        \ && !(cursor_byte_col < len(line) && line[cursor_byte_col] ==# '(')
  let current_prefix = yac#_get_current_word_prefix()
  let prefix_byte_len = len(current_prefix)
  let before = cursor_byte_col - prefix_byte_len > 0 ? line[: cursor_byte_col - prefix_byte_len - 1] : ''
  let after = line[cursor_byte_col :]
  let new_line = before . insert_text . after
  call setline('.', new_line)

  " 移动光标到插入文本之后
  let new_cursor_byte = len(before) + len(insert_text) + 1
  call cursor(line('.'), new_cursor_byte)

  " 只在需要加括号时使用 feedkeys
  if add_parens
    call feedkeys("()\<Left>", 'n')
  endif
endfunction

function! s:close_completion_popup() abort
  " 停止待发的补全 timer
  if s:completion.timer_id != -1
    call timer_stop(s:completion.timer_id)
    let s:completion.timer_id = -1
  endif

  " 停止后台补全 timer
  if s:completion.bg_timer_id != -1
    call timer_stop(s:completion.bg_timer_id)
    let s:completion.bg_timer_id = -1
  endif

  " 停止文档 debounce timer
  if s:completion.doc_timer_id != -1
    call timer_stop(s:completion.doc_timer_id)
    let s:completion.doc_timer_id = -1
  endif

  if s:completion.popup_id != -1 && exists('*popup_close')
    " 保留 items 到缓存
    if !empty(s:completion.original_items)
      let s:completion.cache = s:completion.original_items
      let s:completion.cache_file = expand('%:p')
      let s:completion.cache_line = line('.')
    endif
    call popup_close(s:completion.popup_id)
    let s:completion.popup_id = -1
    let s:completion.items = []
    let s:completion.original_items = []
    let s:completion.selected = 0
    let s:completion.trigger_col = 0
  endif
  " 同时关闭文档popup
  call yac_completion_render#close_doc(s:completion)
endfunction

" === Internal: BS Handling ===

function! s:invoke_original_bs() abort
  if !empty(s:saved_bs_map) && get(s:saved_bs_map, 'expr', 0)
    return eval(s:saved_bs_map.rhs)
  elseif !empty(s:saved_bs_map) && !empty(get(s:saved_bs_map, 'rhs', ''))
    return s:saved_bs_map.rhs
  endif
  return "\<BS>"
endfunction

function! s:deferred_completion_bs() abort
  if s:completion.popup_id == -1
    return
  endif
  let l:col = col('.')
  if l:col <= 1
    call s:close_completion_popup()
    return
  endif
  let l:line = getline('.')
  let l:before = strpart(l:line, 0, l:col - 1)
  let l:char = matchstr(l:before, '.$')
  let l:new_before = strpart(l:before, 0, strlen(l:before) - strlen(l:char))
  let l:after = strpart(l:line, l:col - 1)
  call setline('.', l:new_before . l:after)
  call cursor(line('.'), strlen(l:new_before) + 1)
  call yac#did_change()
  call s:filter_completions()
endfunction
