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
    try program(program_ctx);

    try stdout.flush();
    try stderr.flush();
}

const SYSFS_USB_PATH = "/sys/bus/usb/devices";

// var map_devnum_to_id: std.AutoHashMap(usbTypes.UniqueDeviceId, *usbTypes.HubOrEndPointIdentifier) = .empty;
// var map_id_to_devnum: std.AutoHashMap(usbTypes.HubOrEndPointIdentifier, *usbTypes.UniqueDeviceId) = .empty;
var map_id_to_object: std.AutoHashMap(usbTypes.HubOrEndPointIdentifier, *usbTypes.AnyObject) = undefined;
// var map_id_to_parent: std.AutoHashMap(usbTypes.HubOrEndPointIdentifier, ?usbTypes.HubOrEndPointIdentifier) = undefined;
var map_id_to_speed: std.AutoHashMap(usbTypes.HubOrEndPointIdentifier, usbTypes.SpeedClass) = undefined;

pub fn program(ctx: ProgramContext) !void {
    // Unpack
    const alloc = ctx.alloc;
    const stdout = ctx.stdout;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var object_pool: std.heap.MemoryPool(usbTypes.AnyObject) = .init(alloc);
    defer object_pool.deinit();

    // map_devnum_to_id = .init(alloc);
    // defer map_devnum_to_id.deinit();
    // map_id_to_devnum = .init(alloc);
    // defer map_id_to_devnum.deinit();
    map_id_to_object = .init(alloc);
    defer map_id_to_object.deinit();
    // map_id_to_parent = .init(alloc);
    // defer map_id_to_parent.deinit();
    map_id_to_speed = .init(alloc);
    defer map_id_to_speed.deinit();

    var usb_dir = try std.fs.openDirAbsolute(SYSFS_USB_PATH, .{ .iterate = true });
    defer usb_dir.close();

    var usb_dir_it = usb_dir.iterateAssumeFirstIteration();
    while (try usb_dir_it.next()) |entry| {
        std.debug.print("Next entry: {s}/{s} {any}\n", .{ SYSFS_USB_PATH, entry.name, entry.kind });

        const obj_type, const id, const speed, const serial, const devnum = try processDeviceDir(ctx, usb_dir, entry);

        const object: *usbTypes.AnyObject = try object_pool.create();
        object.id = id;
        switch (obj_type) {
            .root_hub => {
                const temp: usbTypes.RootHub = .{
                    .id = id,
                    .speed = speed,
                    .serial = serial,
                    .devnum = devnum.?,
                };
                object.obj = .{ .root_hub = temp };
            },
            .hub => {
                const temp: usbTypes.Hub = .{
                    .id = id,
                    .devnum = devnum.?,
                    .speed = speed,
                };
                object.obj = .{ .hub = temp };
            },
            .endpoint => {
                const temp: usbTypes.Endpoint = .{
                    .id = id,
                    .speed = speed,
                };
                object.obj = .{ .endpoint = temp };
            },
            else => unreachable,
        }

        // No two USB devices should have the id or devnum
        try map_id_to_object.putNoClobber(id, object);
        if (speed) |s| {
            try map_id_to_speed.putNoClobber(id, s);
        }
    }

    {
        var graph: graphviz.Graph = .{
            .directed = true,
        };
        try graph.init(aalloc, "USB graph");
        defer graph.deinit();

        // ----

        var usb_obj_it = map_id_to_object.iterator();
        while (usb_obj_it.next()) |entry| {
            const id = entry.value_ptr.*.id;

            const name = try std.fmt.allocPrint(alloc, "{f}", .{id});
            defer alloc.free(name);
            const node = graph.findNode(name) orelse try graph.newNode(name);
            //

            // if (id.type == .root_hub) {
            //     const root_hub = entry.value_ptr.*.obj.root_hub;
            //     const serial = root_hub.serial.?;

            //     const cluster_name = "cluster_" ++ serial.str;
            //     const cluster = graph.findCluster(cluster_name) orelse try graph.newCluster(cluster_name);
            //     try cluster.addNode(node);
            // }

            var speed = map_id_to_speed.get(id);
            if (speed == null) speed = map_id_to_speed.get(id.parent().?);

            // const speed = map_id_to_speed.get(id).?;
            if (speed) |s| {
                const speed_string = if (s.isUsb2()) "Usb 2.0" else "Usb 3.0";
                const cluster_name = try std.fmt.allocPrint(alloc, "cluster_{s}", .{speed_string});
                defer alloc.free(cluster_name);
                const cluster = graph.findCluster(cluster_name) orelse try graph.newCluster(cluster_name);

                try cluster.addNode(node);
            }

            const parent_id = id.parent() orelse continue;
            {
                const parent_name = try std.fmt.allocPrint(alloc, "{f}", .{parent_id});
                defer alloc.free(parent_name);
                const parent_node = graph.findNode(parent_name) orelse try graph.newNode(parent_name);

                try graph.newEdge(parent_node, node);
            }
        }

        // ----

        try graph.print(stdout);
        try ctx.stdout.flush();
    }

    return;
}

fn processDeviceDir(ctx: ProgramContext, usb_dir: std.fs.Dir, entry: std.fs.Dir.Entry) !struct {
    usbTypes.AnyObjectType,
    usbTypes.HubOrEndPointIdentifier,
    ?usbTypes.SpeedClass,
    usbTypes.PciBdfNumber,
    ?u7,
} {
    // Unpack
    const alloc = ctx.alloc;

    var obj_type: usbTypes.AnyObjectType = undefined;
    var id: usbTypes.HubOrEndPointIdentifier = undefined;
    var speed: ?usbTypes.SpeedClass = null;
    var serial: usbTypes.PciBdfNumber = .{ .str = undefined };
    var devnum: ?u7 = null;

    if (entry.kind == .sym_link) {
        id = try .fromStr(entry.name);

        // Check that it converts back to the same string
        const dev_str = try std.fmt.allocPrint(alloc, "{f}", .{id});
        defer alloc.free(dev_str);
        assert(std.mem.eql(u8, entry.name, dev_str));

        // Conversion process happens to determine the type, too
        obj_type = id.type;

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

                    @memcpy(&serial.str, data);
                }
            } else if (std.mem.eql(u8, "devnum", entry2.name)) {
                std.debug.print("{s}/{s} {any}\n", .{ entry.name, entry2.name, entry2.kind });
                if (id.type == .hub or id.type == .root_hub) {
                    assert(entry2.kind == .file);

                    const raw_data = dev_dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                        std.debug.print("{any}\n", .{err});
                        continue;
                    };
                    defer alloc.free(raw_data);

                    // On linux at least, this file ends with a newline, and parseInt() doesn't like that
                    const data = std.mem.trimEnd(u8, raw_data, "\r\n");

                    // std.debug.print("{s}\n", .{data});
                    // std.debug.print("0x{x}\n", .{data});

                    devnum = try std.fmt.parseUnsigned(u7, data, 10);
                }
            }
        }
    } else {
        unreachable;
    }

    return .{ obj_type, id, speed, serial, devnum };
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
