(function_definition) @function.outer
(function_definition (body) @function.inner)
(parameters (identifier) @parameter.inner)
(if_statement) @conditional.outer
(for_loop) @loop.outer
(while_loop) @loop.outer
(call_expression) @call.outer
(comment) @comment.outer
