const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const zusbview = @import("zusbview");
const usbTypes = zusbview.usbTypes;
const graphviz = zusbview.graphviz;

const usb_max_tiers = usbTypes.usb_max_tiers;

const ProgramContext = struct {
    /// Core allocator used by program
    alloc: Allocator,

    stdin: *std.io.Reader,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
};

pub fn main() !void {
    // memory
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // var debugAllocator: std.heap.DebugAllocator(.{}) = .init;
    // defer assert(debugAllocator.deinit() == .ok); // Check for leaks
    // const alloc: Allocator = debugAllocator.allocator();

    const stdin_buf: []u8 = try alloc.alloc(u8, (16 * 1024));
    defer alloc.free(stdin_buf);
    var stdin_reader = std.fs.File.stdin().reader(stdin_buf);
    const stdin: *std.io.Reader = &stdin_reader.interface;

    const stdout_buf: []u8 = try alloc.alloc(u8, (16 * 1024));
    defer alloc.free(stdout_buf);
    var stdout_writer = std.fs.File.stdout().writer(stdout_buf);
    const stdout: *std.io.Writer = &stdout_writer.interface;

    const stderr_buf: []u8 = try alloc.alloc(u8, (16 * 1024));
    defer alloc.free(stderr_buf);
    var stderr_writer = std.fs.File.stderr().writer(stderr_buf);
    const stderr: *std.io.Writer = &stderr_writer.interface;

    const program_ctx: ProgramContext = .{
        .alloc = alloc,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
    };

    // try program(program_ctx);
    try program2(program_ctx);

    try stdout.flush();
    try stderr.flush();
}

const SYSFS_USB_PATH = "/sys/bus/usb/devices";

pub fn program2(ctx: ProgramContext) !void {
    // Unpack
    const alloc = ctx.alloc;
    const stdout = ctx.stdout;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    // const aalloc = arena.allocator();

    var device_pool: std.heap.MemoryPool(usbTypes.Device) = try .initPreheated(alloc, 100);
    defer device_pool.deinit();
    var root_hub_pool: std.heap.MemoryPool(usbTypes.RootHub) = try .initPreheated(alloc, 10);
    defer root_hub_pool.deinit();

    // // Create a device, which will be copied into the ArrayList once it's done & validated
    // var dev: *usbTypes.Device = try device_pool.create();
    // dev.* = .{
    //     .id = try .fromStr(entry.name), // We can fill this one in right away
    //     .speed = null,
    // };

    //
    var root_hubs: std.ArrayList(*usbTypes.RootHub) = .empty;
    var hubs: std.ArrayList(*usbTypes.Device) = .empty;
    var endpoints: std.ArrayList(*usbTypes.Device) = .empty;

    var usb_dir = try std.fs.openDirAbsolute(SYSFS_USB_PATH, .{ .iterate = true });
    defer usb_dir.close();

    var usb_dir_it = usb_dir.iterateAssumeFirstIteration();
    while (try usb_dir_it.next()) |entry| {
        try stdout.print("Next entry: {s}/{s} {any}\n", .{ SYSFS_USB_PATH, entry.name, entry.kind });
        try stdout.flush();

        var id: usbTypes.HubOrEndPointIdentifier = undefined;
        var speed: ?usbTypes.SpeedClass = null;
        var serial: usbTypes.PciBdfNumber = .{ .str = undefined };

        if (entry.kind == .sym_link) {
            id = try .fromStr(entry.name);

            // Check that it converts back to the same string
            const dev_str = try std.fmt.allocPrint(alloc, "{f}", .{id});
            defer alloc.free(dev_str);
            assert(std.mem.eql(u8, entry.name, dev_str));

            // Open the directory representing the device
            var dev_dir = try usb_dir.openDir(entry.name, .{ .iterate = true });
            defer dev_dir.close();

            var dev_dir_it = dev_dir.iterateAssumeFirstIteration();
            while (try dev_dir_it.next()) |entry2| {
                if (std.mem.eql(u8, "speed", entry2.name)) {
                    std.debug.print("{s}/{s} {any}\n", .{ entry.name, entry2.name, entry2.kind });
                    assert(entry2.kind == .file);

                    const raw_data = dev_dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                        std.debug.print("{any}\n", .{err});
                        continue;
                    };
                    defer alloc.free(raw_data);

                    // On linux at least, this file ends with a newline, and parseInt() doesn't like that
                    const data = std.mem.trimEnd(u8, raw_data, "\r\n");

                    speed = try .fromStringMbps(data);
                    std.debug.print("speed = {}\n", .{speed.?.inMbps()});
                } else if (std.mem.eql(u8, "serial", entry2.name)) {
                    std.debug.print("{s}/{s} {any}\n", .{ entry.name, entry2.name, entry2.kind });
                    if (id.type == .root_hub) {
                        assert(entry2.kind == .file);

                        const raw_data = dev_dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                            std.debug.print("{any}\n", .{err});
                            continue;
                        };
                        defer alloc.free(raw_data);

                        // On linux at least, this file ends with a newline, and parseInt() doesn't like that
                        const data = std.mem.trimEnd(u8, raw_data, "\r\n");

                        std.debug.print("{s}\n", .{data});
                        std.debug.print("0x{x}\n", .{data});

                        @memcpy(&serial.str, data);
                    }
                }
            }

            if (id.type == .root_hub) {
                const root_hub: *usbTypes.RootHub = try root_hub_pool.create();
                root_hub.* = .{
                    .id = id,
                    .speed = speed,
                    .serial = serial,
                };
                try root_hubs.append(alloc, root_hub);
            } else {
                // if (id.type)
                const device: *usbTypes.Device = try device_pool.create();
                device.* = .{
                    .id = id,
                    .speed = speed,
                };
                try switch (id.type) {
                    .hub => hubs.append(alloc, device),
                    .endpoint => endpoints.append(alloc, device),
                    else => unreachable,
                };
            }
        }
    }

    for (root_hubs.items) |root_hub| {
        try stdout.print("{f}: {s}\n", .{ root_hub.id, root_hub.serial.?.str });
    }
    try stdout.flush();

    for (std.enums.values(usbTypes.SpeedClass)) |speed| {
        if (speed == .UNKNOWN) {
            try stdout.print("======== Unknown speed ========\n", .{});
            continue;
        }
        try stdout.print("======== {} Mbps ========\n", .{speed.inMbps()});

        for (hubs.items) |hub| {
            if (hub.speed == speed) {
                try stdout.print("{f}\n", .{hub.id});
            }
        }

        for (endpoints.items) |ep| {
            if (ep.speed == speed) {
                try stdout.print("{f}\n", .{ep.id});
            }
        }
    }
    try stdout.flush();

    //
}

pub fn program(ctx: ProgramContext) !void {
    // Unpack

    // Memory for graphs is free'd in one go
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var count_devices: usize = 0;
    var count_root_hubs: usize = 0;
    var count_hubs: usize = 0;

    var deviceTreeRoot: usbTypes.DeviceTree = .{
        .device = .{
            .type = .root,
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

        const bare_line0 = try ctx.stdin.takeDelimiter('\n') orelse break;
        const line0 = std.mem.trim(u8, bare_line0, "\r");
        const bare_line1 = try ctx.stdin.takeDelimiter('\n') orelse break;
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
            dev.type = .iface;
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
            slice = skipString(slice, "Bus ");
            slice = try parseIntUpTo(slice, '.', u8, &dev.bus);
            slice = skipString(slice, ".");

            // temp
        } else {
            dev.bus = hierarchy[1].device.bus;
        }

        slice = skipString(slice, "Port ");
        slice = try parseIntUpTo(slice, ':', u8, &dev.port);
        slice = skipString(slice, ": Dev ");
        slice = try parseIntUpTo(slice, ',', u8, &dev.dev);

        if (dev.type == .hub or dev.type == .iface) {
            slice = skipString(slice, ", If ");
            slice = try parseIntUpTo(slice, ',', u8, &dev.iface);
        }

        slice = skipString(slice, ", Class=");
        slice = slice[std.mem.sliceTo(slice, ',').len..]; // ignored, for now

        slice = skipString(slice, ", Driver=");
        slice = slice[std.mem.sliceTo(slice, ',').len..]; // ignored, for now

        slice = skipString(slice, ", ");
        slice = try parseUsbSpeed(slice, 'M', &dev.speed);

        // slice = std.mem.trim(u8, slice, " "); // Remove whitespace at start

        // // Check it starts with "ID "
        // assert(std.mem.eql(u8, "ID ", slice[0..3]));
        // slice = slice[3..];

        // id = slice[0..9];

        // Add to device 'tree' so that lower items can figure out who their parent is
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

    try graph.print(ctx.stdout);
    try ctx.stdout.flush();

    try ctx.stderr.print("Root hubs = {}, hubs = {}, devices = {}\n", .{ count_root_hubs, count_hubs, count_devices });
    try ctx.stderr.flush();
}

fn grabLine(reader: *std.io.Reader) ?[]u8 {
    const bare_line = try reader.takeDelimiter('\n') orelse return null;
    const line = std.mem.trim(u8, bare_line, "\r");

    // std.debug.print("length {}: {s}\n", .{ line.len, line });

    return line;
}

fn skipString(slice: []const u8, expected: []const u8) []const u8 {
    assert(std.mem.eql(u8, expected, slice[0..expected.len]));
    return slice[expected.len..];
}

fn parseIntUpTo(slice: []const u8, comptime end: u8, T: type, out: *?T) ![]const u8 {
    const number_str = std.mem.sliceTo(slice, end);
    out.* = std.fmt.parseUnsigned(T, number_str, 10) catch 1;
    return slice[number_str.len..];
}

fn parseUsbSpeed(slice: []const u8, comptime end: u8, out: *?usbTypes.Speed) ![]const u8 {
    const number_str = std.mem.sliceTo(slice, end);
    const mbps = std.fmt.parseUnsigned(u32, number_str, 10) catch 1;

    out.* = switch (mbps) {
        1 => .LOW,
        12 => .FULL,
        480 => .HIGH,
        5000 => .SUPER,
        10000 => .SUPER_PLUS,
        20000 => .SUPER_PLUS_X2,

        else => unreachable,
    };

    out.* =
        return slice[number_str.len..];
}
