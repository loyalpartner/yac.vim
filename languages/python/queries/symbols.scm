; Top-level functions (sync and async share function_definition node type)
(module (function_definition name: (identifier) @name) @function)
(module (decorated_definition
  definition: (function_definition name: (identifier) @name)) @function)

; Top-level classes
(module (class_definition name: (identifier) @name) @class)
(module (decorated_definition
  definition: (class_definition name: (identifier) @name)) @class)

; Methods inside class bodies
(class_definition
  name: (identifier) @impl_type
  body: (block
    (function_definition name: (identifier) @name) @method))
(class_definition
  name: (identifier) @impl_type
  body: (block
    (decorated_definition
      definition: (function_definition name: (identifier) @name)) @method))
