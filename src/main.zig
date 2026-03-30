const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const zusbview = @import("zusbview");
const usbTypes = zusbview.usbTypes;
const usbExtractInfo = zusbview.usbExtractInfo;
const graphviz = zusbview.graphviz;

const settings = @import("settings.zig");

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
var map_id_to_info: std.AutoHashMap(usbTypes.HubOrEndPointIdentifier, *usbExtractInfo.UsbObjectInfo) = undefined;

pub fn program(ctx: ProgramContext) !void {
    // Unpack
    const alloc = ctx.alloc;
    const stdout = ctx.stdout;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aalloc = arena.allocator();

    var obj_pool: std.heap.MemoryPool(usbExtractInfo.UsbObjectInfo) = .init(alloc);
    defer obj_pool.deinit();

    map_id_to_info = .init(alloc);
    defer map_id_to_info.deinit();

    var usb_dir = try std.fs.openDirAbsolute(SYSFS_USB_PATH, .{ .iterate = true });
    defer usb_dir.close();

    var usb_dir_it = usb_dir.iterateAssumeFirstIteration();
    while (try usb_dir_it.next()) |entry| {
        std.debug.print("Next entry: {s}/{s} {any}\n", .{ SYSFS_USB_PATH, entry.name, entry.kind });

        // Open the directory representing the device
        var dev_dir = try usb_dir.openDir(entry.name, .{ .iterate = true });
        defer dev_dir.close();

        const obj: *usbExtractInfo.UsbObjectInfo = try obj_pool.create();
        obj.* = try usbExtractInfo.usbExtractInfo(entry.name, dev_dir, aalloc);

        try map_id_to_info.putNoClobber(obj.parsed.id, obj);
    }

    {
        var graph: graphviz.Graph = .{
            .directed = true,
        };
        try graph.init(aalloc, "USB graph");
        defer graph.deinit();

        // ----

        var usb_obj_it = map_id_to_info.iterator();
        while (usb_obj_it.next()) |entry| {
            const obj = entry.value_ptr.*;
            const id = obj.parsed.id;
            // assert(id == entry.key_ptr.*);

            // Every device, hub and root_hub has an endpoint associated with it; not important to draw
            if (id.id_type() == .endpoint) {
                if (id.iface == 1) {
                    if (id.endpoint == 0) {
                        if (settings.hide_mandatory_endpoint) {
                            continue;
                        }
                    }
                }
            }
            // defer std.debug.print("\n", .{});
            // std.debug.print("id = {f} ({})", .{ id, @intFromEnum(id.type.?) });

            const name = try nameFromId(alloc, obj);
            defer alloc.free(name);

            defer alloc.free(name);
            const node = graph.findNode(name) orelse try graph.newNode(name);

            // Shape indicates type
            node.shape = switch (obj.inferred.type) {
                .root_hub => .house,
                .hub => .diamond,
                .device => .box,
                .endpoint => .invhouse,
                // else => .star, // indicates an error
            };

            // if (id.type == .root_hub) {
            //     const root_hub = entry.value_ptr.*.obj.root_hub;
            //     const serial = root_hub.serial.?;

            //     const cluster_name = "cluster_" ++ serial.str;
            //     const cluster = graph.findCluster(cluster_name) orelse try graph.newCluster(cluster_name);
            //     try cluster.addNode(node);
            // }

            var speed = obj.parsed.speed;
            std.debug.print("self:{f}\n", .{id});
            if (id.parent()) |p| {
                std.debug.print("prnt:{f}\n", .{p});
            }
            if (speed == null) {
                const parent = map_id_to_info.get(id.parent().?);
                if (parent) |p| {
                    speed = p.parsed.speed.?;
                }
            }

            // const speed = map_id_to_speed.get(id).?;
            if (speed) |s| {
                const speed_string = if (s.isUsb2()) "Usb 2.0" else "Usb 3.0";
                const cluster_name = try std.fmt.allocPrint(alloc, "cluster_{s}", .{speed_string});
                defer alloc.free(cluster_name);
                const cluster = graph.findCluster(cluster_name) orelse try graph.newCluster(cluster_name);

                try cluster.addNode(node);
            } else {
                // This bit of code is probably not needed
                const speed_string = "UNKNOWN SPEED";
                const cluster_name = try std.fmt.allocPrint(alloc, "cluster_{s}", .{speed_string});
                defer alloc.free(cluster_name);
                const cluster = graph.findCluster(cluster_name) orelse try graph.newCluster(cluster_name);

                try cluster.addNode(node);
            }

            if (obj.inferred.type == .root_hub) {
                // Add a node for the PCI serial number
                const parent_name = "PCI\n" ++ obj.parsed.serial.?.str;
                const parent_node = graph.findNode(parent_name) orelse try graph.newNode(parent_name);

                try graph.newEdge(parent_node, node);
            }

            const parent_id = id.parent() orelse continue;
            std.debug.print("  parent = {f}\n", .{parent_id});

            {
                const parent_obj = map_id_to_info.get(parent_id) orelse {
                    std.debug.print("No parent in map!", .{});
                    continue;
                };

                const parent_name = try nameFromId(alloc, parent_obj);
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

fn nameFromId(gpa: Allocator, obj: *const usbExtractInfo.UsbObjectInfo) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{f}", .{obj.*});
}
