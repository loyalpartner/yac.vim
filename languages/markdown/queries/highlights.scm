; Headings (Zed-style: entire heading node highlighted)
[
  (atx_heading)
  (setext_heading)
] @markup.heading

(setext_heading
  (paragraph) @markup.heading)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @markup.heading.marker

; List markers
[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
] @markup.list.marker

; Task list
(task_list_marker_checked) @markup.list.checked
(task_list_marker_unchecked) @markup.list.unchecked

; Block quotes
(block_quote_marker) @markup.quote

; Code blocks
[
  (fenced_code_block_delimiter)
  (info_string)
] @punctuation.special

; Code fence content gets language-specific highlighting via injections.scm
; Fallback for code blocks without a recognized language
(fenced_code_block
  (code_fence_content) @string)

; Links
(link_destination) @markup.link.url
(link_label) @markup.link.label
(link_reference_definition) @markup.link.label

; Horizontal rule
(thematic_break) @punctuation.special

; Escape
(backslash_escape) @string.escape
