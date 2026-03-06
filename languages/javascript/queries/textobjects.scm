; Functions
(function_declaration) @function.outer
(function_declaration
  body: (statement_block) @function.inner)

(function_expression) @function.outer
(function_expression
  body: (statement_block) @function.inner)

(arrow_function) @function.outer
(arrow_function
  body: (statement_block) @function.inner)

(method_definition) @function.outer
(method_definition
  body: (statement_block) @function.inner)

; Classes
(class_declaration) @class.outer
(class_declaration
  body: (class_body) @class.inner)

(class_expression) @class.outer
(class_expression
  body: (class_body) @class.inner)

; Parameters
(formal_parameters
  [
    (identifier)
    (assignment_pattern)
    (rest_element)
    (object_pattern)
    (array_pattern)
  ] @parameter.inner)

; Conditionals
(if_statement) @conditional.outer
(switch_statement) @conditional.outer

; Loops
(for_statement) @loop.outer
(for_in_statement) @loop.outer
(while_statement) @loop.outer
(do_statement) @loop.outer

; Blocks
(statement_block) @block.outer

; Calls
(call_expression) @call.outer

; Comments
(comment) @comment.outer
