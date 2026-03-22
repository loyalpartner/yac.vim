pub const Engine = @import("engine.zig").Engine;
pub const LangState = @import("engine.zig").LangState;
pub const GroupHighlights = @import("highlights.zig").GroupHighlights;
pub const Span = @import("highlights.zig").Span;
pub const highlights = @import("highlights.zig");
pub const predicates = @import("predicates.zig");
pub const WasmLoader = @import("wasm_loader.zig").WasmLoader;
pub const lang_config = @import("lang_config.zig");
pub const outline = @import("outline.zig");
pub const queries = @import("queries.zig");
pub const file_io = @import("file_io.zig");

test {
    _ = @import("predicates.zig");
    _ = @import("highlights.zig");
    _ = @import("engine.zig");
    _ = @import("lang_config.zig");
    _ = @import("outline.zig");
    _ = @import("file_io.zig");
}
