; Fold at the statement level so that the fold indicator sits on the
; keyword line (def/class/if/for/…), not on the first body line.
; Using (block) @fold would start the fold one line below the keyword
; because Python blocks begin at the first indented line.
(function_definition) @fold
(class_definition) @fold
(if_statement) @fold
(for_statement) @fold
(while_statement) @fold
(try_statement) @fold
(with_statement) @fold
