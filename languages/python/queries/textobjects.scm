; Functions
(function_definition) @function.outer
(function_definition body: (block) @function.inner)

; Classes
(class_definition) @class.outer
(class_definition body: (block) @class.inner)

; Parameters
(parameters (identifier) @parameter.inner)
(parameters (default_parameter) @parameter.inner)
(parameters (typed_parameter) @parameter.inner)
(parameters (typed_default_parameter) @parameter.inner)

; Conditionals
(if_statement) @conditional.outer

; Loops
(for_statement) @loop.outer
(while_statement) @loop.outer

; Calls
(call) @call.outer

; Comments
(comment) @comment.outer

; Decorators
(decorator) @decorator.outer
