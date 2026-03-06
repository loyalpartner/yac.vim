(function_definition) @function.outer
(function_definition body: (compound_statement) @function.inner)

(class_specifier body: (field_declaration_list)) @class.outer
(class_specifier body: (field_declaration_list) @class.inner)
(struct_specifier body: (field_declaration_list)) @class.outer
(struct_specifier body: (field_declaration_list) @class.inner)
(enum_specifier body: (enumerator_list)) @class.outer
(enum_specifier body: (enumerator_list) @class.inner)
(union_specifier body: (field_declaration_list)) @class.outer
(namespace_definition body: (declaration_list)) @class.outer

(parameter_list (parameter_declaration) @parameter.inner)

(if_statement) @conditional.outer
(for_statement) @loop.outer
(for_range_loop) @loop.outer
(while_statement) @loop.outer
(do_statement) @loop.outer

(compound_statement) @block.outer
(call_expression) @call.outer
(comment) @comment.outer
