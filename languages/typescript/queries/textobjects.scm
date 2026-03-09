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

; Method signatures (no body)
(method_signature) @function.outer

; Classes
(class_declaration) @class.outer
(class_declaration
  body: (class_body) @class.inner)

; Interfaces
(interface_declaration) @class.outer
(interface_declaration
  body: (object_type) @class.inner)

; Parameters
(formal_parameters
  [
    (identifier)
    (required_parameter)
    (optional_parameter)
    (rest_parameter)
    (assignment_pattern)
    (object_pattern)
    (array_pattern)
  ] @parameter.inner)

; Conditionals
(if_statement) @conditional.outer
(switch_statement) @conditional.outer
(ternary_expression) @conditional.outer

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
