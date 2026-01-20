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

    var line_no: usize = 0;
    while (true) {
        const bare_line = try stdin.takeDelimiter('\n') orelse break;
        const line = std.mem.trim(u8, bare_line, "\r");
        line_no += 1;

        try stdout.print("line {}, length {}: {s}\n", .{ line_no, line.len, line });
        try stdout.flush();
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
