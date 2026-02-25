(function_item name: (identifier) @name) @function
(struct_item name: (type_identifier) @name) @struct
(enum_item name: (type_identifier) @name) @enum
(union_item name: (type_identifier) @name) @union
(trait_item name: (type_identifier) @name) @trait
(mod_item name: (identifier) @name) @module
(macro_definition name: (identifier) @name) @macro
(impl_item type: (type_identifier) @impl_type
  body: (declaration_list
    (function_item name: (identifier) @name) @method))
