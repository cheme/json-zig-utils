//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;

// TODO split between comptime and non comptime (allow both defs depending on small or large build).
pub const Options = struct {
    indent: bool = true,
};

const ZonContext = union(enum) {
    @"struct": std.zon.Serializer.Struct,
    tuple: std.zon.Serializer.Tuple,
    free,
};

const ZonStack = ArrayList(ZonContext);
const zon_stack_capacity = 20; // TODO in opts?

pub fn jsonToZon(alloc: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer, opts: Options) !void {
    // TODO full json slice ? generally scanner is awkward
    var scanner: std.json.Scanner = .initStreaming(alloc);
    defer scanner.deinit();

    var zon_writer: std.zon.Serializer = .{
        .writer = writer,
        .options = .{ .whitespace = opts.indent },
    };

    var zon_stack: ZonStack = try .initCapacity(alloc, zon_stack_capacity);
    defer zon_stack.deinit(alloc);
    // TODO just a ScannerReader struct here ?
    scanner.feedInput(reader.buffered());
    reader.tossBuffered();
    while (true) {
        const token = scanner.next() catch |e| switch (e) {
            error.BufferUnderrun => {
                reader.fillMore() catch switch (e) {
                    error.BufferUnderrun => {
                        if (zon_stack.items.len > 0)
                            return std.json.Error.SyntaxError;
                        // end of stream
                        return;
                    },
                    else => return e,
                };
                scanner.feedInput(reader.buffered());
                continue;
            },
            else => return e,
        };
        switch (token) {
            .object_begin => {
                // TODO dyn wrap from our options?
                const new_struct = try zon_writer.beginStruct(.{ .whitespace_style = .{ .wrap = opts.indent } });
                // TODO optionally do not stack (trust input), note that all struct uses same option so same content:
                // should use comptime struct everywhere and only stack enum actually. (api is misleading should redisign
                // std). (just need to set back serializer)
                try zon_stack.append(alloc, .{ .@"struct" = new_struct });
            },
            .object_end => {
                if (zon_stack.pop()) |*last| {
                    // TODO lib error
                    if (last.* != .@"struct")
                        return std.json.Error.SyntaxError;
                    // TODO end fn should be on const in the first place
                    try @constCast(&last.@"struct").end();
                    // TODO lib error
                } else return std.json.Error.SyntaxError;
            },
            //.partial_number => {
            //},

            .end_of_document => break,
            else => {
                std.debug.print("\n unimpl token {any}\n", .{token});
                unreachable;
            },
        }
    }
    return;
}

test "empty" {
    const json = "{}";
    const alloc = std.testing.allocator;
    var read_stream = std.Io.Reader.fixed(json);
    var out_stream = std.Io.Writer.Allocating.initCapacity(alloc, json.len) catch unreachable;
    defer out_stream.deinit();
    jsonToZon(alloc, &read_stream, &out_stream.writer, .{
        // no format to avoid minor formating change and test breakage.
        .indent = false,
    }) catch unreachable;
    const zon = out_stream.toOwnedSlice() catch unreachable;
    defer alloc.free(zon);
    try std.testing.expectEqualSlices(u8, ".{}", zon);
}
