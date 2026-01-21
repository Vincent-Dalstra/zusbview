const std = @import("std");
const assert = std.debug.assert;

const zusbview = @import("zusbview");

const UsbType = enum {
    not_recognised,
    root_hub,
    hub,
    device,
};

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
    var count_hubs: usize = 0;

    var prev_depth: u8 = 0;
    while (true) {
        var usb_type: ?UsbType = null;
        var depth: u8 = 0;

        const bare_line0 = try stdin.takeDelimiter('\n') orelse break;
        const line0 = std.mem.trim(u8, bare_line0, "\r");
        const bare_line1 = try stdin.takeDelimiter('\n') orelse break;
        const line1 = std.mem.trim(u8, bare_line1, "\r");

        std.debug.print("length {}: {s}\n", .{ line0.len, line0 });
        std.debug.print("length {}: {s}\n", .{ line1.len, line1 });

        if (0 < std.mem.count(u8, line0, "Class=root_hub")) {
            usb_type = .root_hub;
            count_root_hubs += 1;
        } else if (0 < std.mem.count(u8, line0, "Class=Hub")) {
            usb_type = .hub;
            count_hubs += 1;
        } else {
            usb_type = .device;
            count_devices += 1;
        }

        var slice = line0;
        while (true) {
            if (std.mem.eql(u8, "    ", slice[0..4])) {
                slice = slice[4..];
                depth += 1;
                continue;
            } else if (std.mem.eql(u8, "/:  ", slice[0..4])) {
                assert(depth == 0);
                assert(usb_type.? == .root_hub);
            } else if (std.mem.eql(u8, "|__ ", slice[0..4])) {
                assert(depth >= 1);
            } else {
                unreachable;
            }
        }

        // Only 3 chained hubs are permitted by USB spec
        if (usb_type == .hub) assert(depth <= 3);
        if (usb_type == .device) assert(depth <= 4);

        assert(depth <= prev_depth + 1);

        prev_depth = depth;
    }
    try stdout.print("Root hubs = {}, hubs = {}, devices = {}\n", .{ count_root_hubs, count_hubs, count_devices });
    try stdout.flush();
}

fn grabLine(reader: *std.io.Reader) ?[]u8 {
    const bare_line = try reader.takeDelimiter('\n') orelse return null;
    const line = std.mem.trim(u8, bare_line, "\r");

    std.debug.print("length {}: {s}\n", .{ line.len, line });

    return line;
}
