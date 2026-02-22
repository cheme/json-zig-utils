const std = @import("std");
const Io = std.Io;

const json_utils = @import("json_zig_utils");

pub fn main(init: std.process.Init) !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    // convert all json in input folder to zon in output folder.

    // TODO async all file on green threads
    const io = init.io;
    const input_path = "input";
    const output_path = "output";
    const cwd = std.Io.Dir.cwd();
    const inputs = try cwd.openDir(io, input_path, .{
        // no depth recursion
        .access_sub_paths = false,
        .iterate = true,
        .follow_symlinks = true,
    });
    defer inputs.close(io);
    // TODO a openDirOrCreate function (avoid this pattern, just
    // create on FileNotFound and reopen once).
    if (cwd.access(io, output_path, .{}) == error.FileNotFound)
        try cwd.createDir(io, output_path, .default_dir);
    const outputs = try cwd.openDir(io, output_path, .{
        // no depth recursion
        .access_sub_paths = false,
        .iterate = true,
        .follow_symlinks = true,
    });
    defer outputs.close(io);

    // TODO implement using Reader and Walker?
    // TODO 2048 buf for filename (uf16 255 ntfs? or others
    // exotic 1023?).
    var it_inputs = inputs.iterateAssumeFirstIteration();
    while (try it_inputs.next(io)) |entry| {
        const in_extension = ".json";
        const out_extension = ".zon";
        if (entry.kind == .file and
            std.mem.eql(u8, in_extension, std.fs.path.extension(entry.name)))
        {
            std.debug.print("\n{any}", .{entry});
            // overkill len agani
            var out_name_buf: [std.Io.Dir.Iterator.reader_buffer_len]u8 = undefined;
            const base_name_len = entry.name.len - in_extension.len;
            @memcpy(out_name_buf[0..base_name_len], entry.name[0..base_name_len]);
            const out_name_len = base_name_len + out_extension.len;
            @memcpy(out_name_buf[base_name_len..out_name_len], out_extension);
            const in_file = try inputs.openFile(io, entry.name, .{
                .mode = .read_only,
            });

            const out_file = try outputs.createFile(io, out_name_buf[0..out_name_len], .{
                .read = false,
                .truncate = true,
            });

            var reader_buf: [1024]u8 = undefined;
            var reader = std.Io.File.reader(in_file, io, &reader_buf);
            var writer = std.Io.File.writer(out_file, io, &.{});
            //try writer.interface.writeAll("dd");

            try json_utils.jsonToZon(init.gpa, &reader.interface, &writer.interface, .{ .indent = true });

            try writer.flush();
            defer out_file.close(io);
        }
    }
}
