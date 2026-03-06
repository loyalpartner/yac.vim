; Functions
(function_declaration) @function.outer
(function_declaration
  body: (block) @function.inner)

(local_function_statement) @function.outer
(local_function_statement
  body: (block) @function.inner)

(function_definition) @function.outer
(function_definition
  body: (block) @function.inner)

; Parameters
(parameters
  (identifier) @parameter.inner)

; Conditionals
(if_statement) @conditional.outer

; Loops
(for_statement) @loop.outer
(generic_for_statement) @loop.outer
(while_statement) @loop.outer
(repeat_statement) @loop.outer

; Blocks
(do_statement) @block.outer

; Calls
(function_call) @call.outer

; Comments
(comment) @comment.outer
