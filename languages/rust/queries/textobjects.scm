(function_item) @function.outer
(function_item body: (block) @function.inner)
(struct_item) @class.outer
(struct_item body: (field_declaration_list) @class.inner)
(enum_item) @class.outer
(enum_item body: (enum_variant_list) @class.inner)
(trait_item) @class.outer
(impl_item) @class.outer
(parameters (parameter) @parameter.inner)
(if_expression) @conditional.outer
(for_expression) @loop.outer
(while_expression) @loop.outer
(loop_expression) @loop.outer
(block) @block.outer
(call_expression) @call.outer
(line_comment) @comment.outer
(block_comment) @comment.outer
