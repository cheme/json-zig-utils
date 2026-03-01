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
    //    // needing this buff is so bad, but we have to check for invalid keys or escape needed key.
    //    // should just read ahead tbh.

    var buff_key: std.Io.Writer.Allocating = try .initCapacity(alloc, 128);
    defer buff_key.deinit();
    var reading_buff_key = false;
    // TODO just a ScannerReader struct here ?
    scanner.feedInput(reader.buffered());
    while (true) {
        const token = try nextToken(&scanner, reader) orelse {
            if (zon_stack.items.len > 0)
                return std.json.Error.SyntaxError;
            // end of stream
            break;
        };

        switch (token) {
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
            .end_of_document => break,
            else => {},
        }

        if (zon_stack.items.len > 0)
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
            .object_end => unreachable,
            .array_end => unreachable,
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
            .partial_number => |slice| {
                try readSplitNumber(&scanner, reader, &zon_writer, slice);
            },
            .number => |n| {
                try zon_writer.writer.writeAll(n);
            },
            .partial_string => |slice| {
                if (reading_buff_key) {
                    try readSplitJsonKey(&scanner, reader, &buff_key.writer, slice);
                    try zon_stack.items[zon_stack.items.len - 1].@"struct".fieldPrefix(buff_key.writer.buffered());
                    _ = buff_key.writer.consumeAll();
                    continue;
                } else {
                    try readSplitString(&scanner, reader, &zon_writer, slice);
                }
            },
            .partial_string_escaped_1 => |c1| {
                if (reading_buff_key) unreachable("unimplemented, should just refactor all serializer");
                try readSplitString(&scanner, reader, &zon_writer, &c1);
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
            .false => {
                try zon_writer.writer.writeAll("false");
                continue;
            },
            .true => {
                try zon_writer.writer.writeAll("true");
                continue;
            },
            .end_of_document => unreachable,
            else => {
                std.debug.print("\n unimpl token {any}\n", .{token});
                unreachable;
            },
        }
    }

    return;
}

fn nextToken(scanner: *std.json.Scanner, reader: *std.Io.Reader) !?std.json.Token {
    while (true) {
        const token = scanner.next() catch |e| switch (e) {
            error.BufferUnderrun => {
                reader.tossBuffered();
                reader.fillMore() catch switch (e) {
                    error.BufferUnderrun => return null,
                    else => return e,
                };
                scanner.feedInput(reader.buffered());
                continue;
            },
            else => return e,
        };
        return token;
    }
}

fn readSplitNumber(scanner: *std.json.Scanner, reader: *std.Io.Reader, zon_ser: *std.zon.Serializer, start_partial: []const u8) !void {
    try zon_ser.writer.writeAll(start_partial);
    while (true) {
        const token = try nextToken(scanner, reader) orelse {
            // no ending number on end of content, just return.
            return;
        };
        switch (token) {
            .partial_number => |slice| try zon_ser.writer.writeAll(slice),
            .number => |s| {
                try zon_ser.writer.writeAll(s);
                return;
            },
            else => return std.json.Error.SyntaxError,
        }
    }
}

fn readSplitString(scanner: *std.json.Scanner, reader: *std.Io.Reader, zon_ser: *std.zon.Serializer, start_partial: []const u8) !void {
    try zon_ser.writer.print("\"{f}", .{std.zig.fmtString(start_partial)});
    while (true) {
        const token = try nextToken(scanner, reader) orelse {
            // no ending number on end of content, just return.
            try zon_ser.writer.writeByte('\"');
            return;
        };
        // TODO code from string above
        switch (token) {
            .partial_string => |slice| {
                try zon_ser.writer.print("{f}", .{std.zig.fmtString(slice)});
            },
            .partial_string_escaped_1 => |c1| {
                // TODO fmtString same?
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
                try zon_ser.writer.writeAll(escaped);
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
                try zon_ser.writer.print("{f}", .{std.zig.fmtString(slice)});
                try zon_ser.writer.writeByte('\"');
                return;
            },
            else => return std.json.Error.SyntaxError,
        }
    }
}

fn readSplitJsonKey(scanner: *std.json.Scanner, reader: *std.Io.Reader, writer: *std.Io.Writer, start_partial: []const u8) !void {
    try writer.writeAll(start_partial);
    while (true) {
        const token = try nextToken(scanner, reader) orelse {
            // expect ending string, end of stream is also wrong (key without value).
            return std.json.Error.SyntaxError;
        };
        switch (token) {
            .partial_string => |slice| try writer.writeAll(slice),
            .partial_string_escaped_1 => |c1| try writer.writeAll(&c1),
            .partial_string_escaped_2 => |c2| try writer.writeAll(&c2),
            .partial_string_escaped_3 => |c3| try writer.writeAll(&c3),
            .partial_string_escaped_4 => |c4| try writer.writeAll(&c4),
            .string => |s| {
                try writer.writeAll(s);
                return;
            },
            else => return std.json.Error.SyntaxError,
        }
    }
}

test "json_to_zon" {
    const tests = .{
        .{
            \\"test \tSo"
            ,
            \\"test \tSo"
        },
        .{
            \\"test \"So"
            ,
            \\"test \"So"
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
