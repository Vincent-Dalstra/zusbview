const std = @import("std");
const assert = std.debug.assert;

const zusbview = @import("zusbview");
const usbTypes = zusbview.usbTypes;
const graphviz = zusbview.graphviz;

const usb_max_tiers = usbTypes.usb_max_tiers;

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

    const stderr_buf: []u8 = try aalloc.alloc(u8, (16 * 1024));
    var stderr_writer = std.fs.File.stderr().writer(stderr_buf);
    const stderr: *std.io.Writer = &stderr_writer.interface;

    var count_devices: usize = 0;
    var count_root_hubs: usize = 0;
    var count_hubs: usize = 0;

    var deviceTreeRoot: usbTypes.DeviceTree = .{
        .device = .{
            .type = .root,
            .nameField = "root",
        },
        .node = .{},
    };

    var hierarchy: [7]*usbTypes.DeviceTree = undefined;
    hierarchy[0] = &deviceTreeRoot;

    var prev_depth: u8 = 0;
    while (true) {
        var dev: usbTypes.Device = .{
            .type = undefined,
        };

        var depth: u8 = 1;

        const bare_line0 = try stdin.takeDelimiter('\n') orelse break;
        const line0 = std.mem.trim(u8, bare_line0, "\r");
        const bare_line1 = try stdin.takeDelimiter('\n') orelse break;
        const line1 = std.mem.trim(u8, bare_line1, "\r");
        _ = line1;

        // std.debug.print("length {}: {s}\n", .{ line0.len, line0 });
        // std.debug.print("length {}: {s}\n", .{ line1.len, line1 });

        if (0 < std.mem.count(u8, line0, "Class=root_hub")) {
            dev.type = .root_hub;
            count_root_hubs += 1;
        } else if (0 < std.mem.count(u8, line0, "Class=Hub")) {
            dev.type = .hub;
            count_hubs += 1;
        } else {
            dev.type = .device;
            count_devices += 1;
        }

        var slice = line0;
        while (true) {
            if (std.mem.eql(u8, "    ", slice[0..4])) {
                slice = slice[4..];

                depth += 1;
                continue;
            } else if (std.mem.eql(u8, "/:  ", slice[0..4])) {
                slice = slice[4..];

                assert(depth == 1);
                assert(dev.type == .root_hub);
                break;
            } else if (std.mem.eql(u8, "|__ ", slice[0..4])) {
                slice = slice[4..];

                assert(depth >= 2);
                break;
            } else {
                unreachable;
            }
            unreachable;
        }

        // Only 5 chained hubs are permitted by USB spec (Root hub = 'Tier 1', max device 'Tier 7')
        if (dev.type == .hub) assert(depth <= (usb_max_tiers - 1));
        if (dev.type == .device) assert(depth <= usb_max_tiers);

        // lsusb -tv shows them in order, so we shouldn't jump a tier!
        assert(depth <= prev_depth + 1);

        // need a unique name... we can use the 'ID' on the second line

        if (dev.type == .root_hub) {
            assert(std.mem.eql(u8, "Bus ", slice[0..4]));
            slice = slice[4..];

            {
                const nstr = std.mem.sliceTo(slice, '.');
                dev.bus = try std.fmt.parseUnsigned(u8, nstr, 10);
                slice = slice[(nstr.len)..];
            }

            assert(std.mem.eql(u8, ".", slice[0..1]));
            slice = slice[1..];

            // temp
        } else {
            dev.bus = hierarchy[1].device.bus;
        }

        assert(std.mem.eql(u8, "Port ", slice[0..5]));
        slice = slice[5..];

        {
            const nstr = std.mem.sliceTo(slice, ':');
            dev.port = try std.fmt.parseUnsigned(u8, nstr, 10);
            slice = slice[(nstr.len)..];
        }

        assert(std.mem.eql(u8, ": Dev ", slice[0..6]));
        slice = slice[6..];

        {
            const nstr = std.mem.sliceTo(slice, ',');
            dev.dev = try std.fmt.parseUnsigned(u8, nstr, 10);
            slice = slice[(nstr.len)..];
        }

        try dev.calcName(aalloc);

        // slice = std.mem.trim(u8, slice, " "); // Remove whitespace at start

        // // Check it starts with "ID "
        // assert(std.mem.eql(u8, "ID ", slice[0..3]));
        // slice = slice[3..];

        // id = slice[0..9];

        // Add to device tree
        hierarchy[depth] = try hierarchy[depth - 1].newDevice(
            aalloc,
            dev,
        );

        prev_depth = depth;
    }

    var graph: graphviz.Graph = .{
        .directed = true,
    };
    try graph.init(aalloc, "USB graph");
    defer graph.deinit();

    try deviceTreeRoot.exportDot(&graph);

    try graph.print(stdout);
    try stdout.flush();

    try stderr.print("Root hubs = {}, hubs = {}, devices = {}\n", .{ count_root_hubs, count_hubs, count_devices });
    try stderr.flush();
}

fn grabLine(reader: *std.io.Reader) ?[]u8 {
    const bare_line = try reader.takeDelimiter('\n') orelse return null;
    const line = std.mem.trim(u8, bare_line, "\r");

    // std.debug.print("length {}: {s}\n", .{ line.len, line });

    return line;
}
