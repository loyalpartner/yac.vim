(function_declaration) @function.outer
(function_declaration body: (block) @function.inner)
(method_declaration) @function.outer
(method_declaration body: (block) @function.inner)
(type_declaration (type_spec type: (struct_type))) @class.outer
(type_declaration (type_spec type: (interface_type))) @class.outer
(parameter_list (parameter_declaration) @parameter.inner)
(if_statement) @conditional.outer
(for_statement) @loop.outer
(block) @block.outer
(call_expression) @call.outer
(comment) @comment.outer
