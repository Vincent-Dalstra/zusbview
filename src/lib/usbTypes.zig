// Types

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const LinkedTree = @import("LinkedTree.zig");

const graphviz = @import("graphviz.zig");

pub const usb_max_tiers = 7; // Tier 1 = root hub. other hubs are tier 2-6, devices are tier 1-7;

pub const DeviceType = enum {
    root, // Dummy item to make the tree work

    not_recognised,
    root_hub,
    hub,
    device,
    iface,
};

const kilo = 1000;
const mega = 1000 * kilo;
const giga = 1000 * mega;

pub const Speed = enum(u64) {
    UNKNOWN = 0,
    LOW = 1.5 * mega,
    FULL = 12 * mega,
    HIGH = 480 * mega,
    SUPER = 5 * giga,
    SUPER_PLUS = 10 * giga,
    SUPER_PLUS_X2 = 20 * giga,

    pub fn inMbps(self: Speed) u32 {
        return @intCast(@intFromEnum(self) / mega);
    }
};

pub const Device = struct {
    type: DeviceType,

    bus: ?u8 = null,
    port: ?u8 = null,
    dev: ?u8 = null,
    iface: ?u8 = null,

    speed: ?Speed = null,

    pub fn getUniqueName(self: *Device, alloc: Allocator) ![]u8 {
        return switch (self.type) {
            .root => try std.fmt.allocPrint(alloc, "Root", .{}),
            .root_hub => try std.fmt.allocPrint(alloc, "ROOT HUB\nBus {}\nDev {}\n{} Mbps", .{ self.bus.?, self.dev.?, self.speed.?.inMbps() }),
            .hub => try std.fmt.allocPrint(alloc, "HUB\nBus {}\nDev {}\n{} Mbps", .{ self.bus.?, self.dev.?, self.speed.?.inMbps() }),
            .iface => try std.fmt.allocPrint(alloc, "Bus {}\nDev {}\n iface {}\n{} Mbps", .{ self.bus.?, self.dev.?, self.iface.?, self.speed.?.inMbps() }),
            .device => try std.fmt.allocPrint(alloc, "Bus {}\nDev {}\n{} Mbps", .{ self.bus.?, self.dev.?, self.speed.?.inMbps() }),
            else => unreachable,
        };
    }
};

pub const DeviceTree = struct {
    node: LinkedTree.Node = .{},

    device: Device,

    pub fn newDevice(self: *DeviceTree, arena: Allocator, new: Device) !*DeviceTree {
        const newNode = try arena.create(DeviceTree);
        newNode.* = .{
            .node = .{},
            .device = new,
        };
        self.node.attachItem(&newNode.node);

        return newNode;
    }

    pub fn exportDot(self: *DeviceTree, graph: *graphviz.Graph) !void {
        const rootNode = try graph.newNode("root");

        try exportDotRecursive(self, graph, rootNode);
    }

    fn exportDotRecursive(parentDev: *DeviceTree, graph: *graphviz.Graph, parentGraphNode: *graphviz.Graph.Node) !void {
        var nextChildNode = parentDev.node.child;
        while (nextChildNode) |childNode| {
            const child: *DeviceTree = @fieldParentPtr("node", childNode);

            var buf: [200]u8 = undefined;
            var fixedBufAllocator = std.heap.FixedBufferAllocator.init(&buf);
            const fballoc = fixedBufAllocator.allocator();

            switch (child.device.type) {
                .root_hub, .hub => {
                    const name = try child.device.getUniqueName(fballoc);

                    // Add to the graph
                    const newGraphNode = try graph.newNode(name);
                    try graph.newEdge(parentGraphNode, newGraphNode);

                    if (childNode.child != null) {
                        try exportDotRecursive(child, graph, newGraphNode);
                    }
                },
                .iface => {
                    const iface_name = try child.device.getUniqueName(fballoc);

                    var temp = child.device;
                    temp.type = .device;
                    const dev_name = try temp.getUniqueName(fballoc);

                    if (!graph.hasNode(dev_name)) {
                        const newGraphNode = try graph.newNode(dev_name);
                        try graph.newEdge(parentGraphNode, newGraphNode);
                    }

                    const newGraphNode = try graph.newNode(iface_name);
                    try graph.newEdge(graph.findNode(dev_name).?, newGraphNode);
                },
                else => unreachable,
            }

            nextChildNode = childNode.next;
        }
    }
};
