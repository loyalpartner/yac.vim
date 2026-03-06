; Inline content → markdown_inline parser
((inline) @injection.content
  (#set! injection.language "markdown_inline"))

; Fenced code blocks → language from info_string
((fenced_code_block
  (info_string) @injection.language
  (code_fence_content) @injection.content))
