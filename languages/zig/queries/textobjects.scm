(function_declaration) @function.outer
(function_declaration body: (block) @function.inner)
(struct_declaration) @class.outer
(enum_declaration) @class.outer
(union_declaration) @class.outer
(parameters (parameter) @parameter.inner)
(for_statement) @loop.outer
(while_statement) @loop.outer
(if_statement) @conditional.outer
(block) @block.outer
(call_expression) @call.outer
(comment) @comment.outer
