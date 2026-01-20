const std = @import("std");
const zusbview = @import("zusbview");

pub fn main() !void {
    // Memory
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var aalloc = arena.allocator();

    const stdin_buf: []u8 = try aalloc.alloc(u8, (16 * 1024));
    var stdin_reader = std.fs.File.stdin().reader(stdin_buf);
    const stdin: *std.io.Reader = &stdin_reader.interface;

    const stdout_buf: []u8 = try aalloc.alloc(u8, (16 * 1024));
    var stdout_writer = std.fs.File.stdout().writer(stdout_buf);
    const stdout: *std.io.Writer = &stdout_writer.interface;

    try stdout.writeAll("HELLO!\n");
    try stdout.flush();

    var count_devices: usize = 0;
    var count_root_hubs: usize = 0;

    var line_no: usize = 0;
    while (true) {
        const bare_line = try stdin.takeDelimiter('\n') orelse break;
        const line = std.mem.trim(u8, bare_line, "\r");
        line_no += 1;

        if (0 < std.mem.count(u8, line, "root hub")) {
            count_root_hubs += 1;
        } else {
            count_devices += 1;
        }

        std.debug.print("line {}, length {}: {s}\n", .{ line_no, line.len, line });
    }
    try stdout.print("Root hubs = {}, devices = {}\n", .{ count_root_hubs, count_devices });
    try stdout.flush();
}
