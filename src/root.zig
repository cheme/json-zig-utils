//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;

// TODO split between comptime and non comptime (allow both defs depending on small or large build).
pub const Options = struct {
    indent: bool = true,
    // TODO encoder sort keys ? (need crazy buf)
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
    var in_string = false;
    var in_number = false;
    //    // needing this buff is so bad, but we have to check for invalid keys or escape needed key.
    //    // should just read ahead tbh.
    //    var buff_key: ArrayList(u8) = try .initCapacity(alloc, 128);
    //    defer buff_key.deinit(alloc);
    var reading_buff_key = false;
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
                        break;
                    },
                    else => return e,
                };
                scanner.feedInput(reader.buffered());
                continue;
            },
            else => return e,
        };
        if (in_string)
            switch (token) {
                // TODO std should not return string after a partial string...
                .string, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
                else => {
                    in_string = false;
                    try zon_writer.writer.writeByte('\"');
                    if (reading_buff_key) {
                        if (reading_buff_key) unreachable("unimplemented, should just refactor all serializer");
                        //        reading_buff_key = false;
                        //        zon_stack.getLast().@"struct".fieldPrefix(buff_key.items);
                        //        buff_key.clearRetainingCapacity();
                    }
                },
            };
        if (in_number)
            switch (token) {
                .partial_number => {},
                else => {
                    in_number = false;
                },
            };

        switch (token) {
            .object_begin => {},
            .array_begin => {},
            .object_end => {
                if (zon_stack.pop()) |*last| {
                    // TODO lib error
                    if (last.* != .@"struct")
                        return std.json.Error.SyntaxError;
                    // TODO end fn should be on const in the first place
                    try @constCast(&last.@"struct").end();
                    // TODO lib error
                } else return std.json.Error.SyntaxError;
                continue;
            },
            .array_end => {
                if (zon_stack.pop()) |*last| {
                    if (last.* != .tuple)
                        return std.json.Error.SyntaxError;
                    try @constCast(&last.tuple).end();
                } else return std.json.Error.SyntaxError;
                continue;
            },
            .partial_number => |slice| {
                // TODO validate number ?  would need number buffer
                // zon nb supposedly same as json?
                if (in_number) {
                    try zon_writer.writer.writeAll(slice);
                    continue;
                }
            },
            .number => {},
            .partial_string => |slice| {
                if (in_string) {
                    // reach escape char
                    // if (slice[0] != '\\') return std.json.Error.SyntaxError;
                    try zon_writer.writer.writeAll(slice);
                    continue;
                }
            },
            .partial_string_escaped_1 => |c1| {
                if (in_string) {
                    const escaped = switch (c1[0]) {
                        '\t' => "\\t",
                        // TODO backspace char?
                        //'b' => "\\b",
                        // TODO form  char?
                        //'\f' => "\\f",
                        '\n' => "\\n",
                        '\r' => "\\r",
                        '\\' => "\\\\",
                        '\"' => "\\\"",
                        else => unreachable,
                    };
                    try zon_writer.writer.writeAll(escaped);
                    continue;
                }
            },
            .partial_string_escaped_2 => |c2| {
                _ = c2; // autofix
                unreachable("TODO impl");
            },
            .partial_string_escaped_3 => |c3| {
                _ = c3; // autofix
                unreachable("TODO impl");
            },
            .partial_string_escaped_4 => |c4| {
                _ = c4; // autofix
                unreachable("TODO impl");
            },
            .string => |slice| {
                if (in_string) {
                    switch (slice[0]) {
                        '\"', '\\' => {
                            // bug with escape " of json reader?
                            try zon_writer.writer.writeByte('\\');
                            try zon_writer.writer.writeAll(slice);
                            continue;
                        },
                        else => {},
                    }
                }
            },
            .end_of_document => break,
            else => {
                std.debug.print("\n unimpl token {any}\n", .{token});
                unreachable;
            },
        }

        if (!in_string and !in_number and zon_stack.items.len > 0)
            // TODO a getlastmut in std TODO try getlast and try to make
            // sense of copy rule
            switch (zon_stack.items[zon_stack.items.len - 1]) {
                .@"struct" => {
                    reading_buff_key = !reading_buff_key;
                },
                .tuple => |*t| {
                    // state on container is wrong and not needed
                    try t.fieldPrefix();
                },
                .free => {},
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
            .array_begin => {
                const new_arr = try zon_writer.beginTuple(.{ .whitespace_style = .{ .wrap = opts.indent } });
                try zon_stack.append(alloc, .{ .tuple = new_arr });
            },
            .object_end => unreachable,
            .array_end => unreachable,
            .partial_number => |slice| {
                try zon_writer.writer.writeAll(slice);
            },
            .number => |n| {
                try zon_writer.writer.writeAll(n);
            },
            .partial_string => |slice| {
                if (reading_buff_key) unreachable("unimplemented, should just refactor all serializer");
                //if (slice[0] != '\"') return std.json.Error.SyntaxError;
                try zon_writer.writer.writeByte('\"');
                in_string = true;
                try zon_writer.writer.writeAll(slice);
                //   std.debug.print("<{s}>", .{slice});
                //  std.debug.print("{any}", .{slice});
            },
            .partial_string_escaped_1 => |c1| {
                if (reading_buff_key) unreachable("unimplemented, should just refactor all serializer");
                const escaped = switch (c1[0]) {
                    '\t' => "\\t",
                    // TODO backspace char?
                    //'b' => "\\b",
                    // TODO form  char?
                    //'\f' => "\\f",
                    '\n' => "\\n",
                    '\r' => "\\r",
                    '\\' => "\\\\",
                    '\"' => "\\\"",
                    else => unreachable,
                };
                try zon_writer.writer.writeAll(escaped);
            },
            .partial_string_escaped_2 => |c2| {
                _ = c2; // autofix
                unreachable("TODO impl");
            },
            .partial_string_escaped_3 => |c3| {
                _ = c3; // autofix
                unreachable("TODO impl");
            },
            .partial_string_escaped_4 => |c4| {
                _ = c4; // autofix
                unreachable("TODO impl");
            },
            .string => |slice| {
                if (reading_buff_key) {
                    try zon_stack.items[zon_stack.items.len - 1].@"struct".fieldPrefix(slice);
                    //reading_buff_key = false;
                } else {
                    try zon_writer.string(slice);
                }
            },
            .end_of_document => unreachable,
            else => {
                std.debug.print("\n unimpl token {any}\n", .{token});
                unreachable;
            },
        }
    }

    if (in_string)
        try zon_writer.writer.writeByte('\"');
    return;
}

test "json_to_zon" {
    const tests = .{
        .{
            \\[
            \\"/* \"Software\"), to deal in the Software without restriction, including    */", 
            \\"/* without limitation the rights to use, copy, modify, merge, publish,    */",
            \\]
            ,
            "a",
        },
        .{ "{}", ".{}" },
        .{ "[]", ".{}" },
        .{ "0", "0" },
        .{ "-23", "-23" },
        .{ "1333.192", "1333.192" },
        .{ "-1333.192", "-1333.192" },
        // TODO implement those
        //.{ "1.0", "1" },
        //.{ "1.10", "1.1" },
        //.{ "1e6", "1000000" },
        //.{ "1E6", "1000000" },
        //.{ "1e-3", "0.001" },
        //.{ "1E-3", "0.001" },
        // TODO test error json read.
        //.{ "007", "7" },
        // TODO std json handling of NaN and Infinities
        //.{ "NaN", "null" },
        //.{ "Infinity", "null" },
        //.{ "-Infinity", "null" },
        .{ "\" hello, world\"", "\" hello, world\"" },
        .{ "\"\\\"hello\"", "\"\\\"hello\"" },
        .{ "\" \\\"hello\"", "\" \\\"hello\"" },
        .{ "\"a\\\\b\"", "\"a\\\\b\"" },
        .{ "\"a\\tb\"", "\"a\\tb\"" },
        .{ "\"a\\rc\"", "\"a\\rc\"" },
        // TODO ? don't relly want to buffer string.
        //.{ "\"hello\"", "hello" },
        .{ "[1, 2]", ".{1,2}" },
        .{ "{ \"a\": 1, \"bb\": 2 }", ".{.a=1,.bb=2}" },
        .{ "{ \"a\": \"aa\", \"bb\": \"bbb\" }", ".{.a=\"aa\",.bb=\"bbb\"}" },
    };

    inline for (tests) |t| {
        testJsonToZon(t[0], t[1]) catch unreachable;
    }
}

fn testJsonToZon(json: []const u8, expected: []const u8) !void {
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
    try std.testing.expectEqualSlices(u8, expected, zon);
}
