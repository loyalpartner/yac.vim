; Top-level function declarations: function foo() ... end
(function_declaration
  name: [
    (identifier) @name
    (dot_index_expression
      field: (identifier) @name)
  ]) @function

; Local function declarations: local function foo() ... end
(local_function_statement
  name: (identifier) @name) @function

; Method declarations: function Obj:method() ... end
(function_declaration
  name: (method_index_expression
    method: (identifier) @name)) @method

; Function assigned to variable: foo = function() ... end
(assignment_statement
  (variable_list
    [
      (identifier) @name
      (dot_index_expression
        field: (identifier) @name)
    ])
  (expression_list
    (function_definition))) @function

; Local variable assigned a function: local foo = function() ... end
(local_variable_declaration
  (variable_list
    (identifier) @name)
  (expression_list
    (function_definition))) @function
