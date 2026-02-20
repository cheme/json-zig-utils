const std = @import("std");
const Io = std.Io;

const json_utils = @import("json_zig_utils");

pub fn main(init: std.process.Init) !void {
    _ = init; // autofix
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
