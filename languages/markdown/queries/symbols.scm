; Markdown headings as document symbols
; H1 → module, H2 → class, H3 → function, H4 → method, H5 → variable, H6 → field
(atx_heading
  (atx_h1_marker)
  (inline) @name) @module

(atx_heading
  (atx_h2_marker)
  (inline) @name) @class

(atx_heading
  (atx_h3_marker)
  (inline) @name) @function

(atx_heading
  (atx_h4_marker)
  (inline) @name) @method

(atx_heading
  (atx_h5_marker)
  (inline) @name) @variable

(atx_heading
  (atx_h6_marker)
  (inline) @name) @field

; Setext-style headings
(setext_heading
  (setext_h1_underline)
  (paragraph) @name) @module

(setext_heading
  (setext_h2_underline)
  (paragraph) @name) @class
