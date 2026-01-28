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
};

pub const Device = struct {
    type: DeviceType,

    nameField: ?[]const u8 = null,

    bus: u8 = undefined,
    port: u8 = undefined,
    dev: u8 = undefined,
    iface: u8 = undefined,

    pub fn getName(self: Device) []const u8 {
        return self.nameField.?;
    }

    pub fn calcName(self: *Device, alloc: Allocator) !void {
        self.nameField = switch (self.type) {
            .root_hub, .hub => try std.fmt.allocPrint(alloc, "Bus {}\nDev {}", .{ self.bus, self.dev }),
            .device => try std.fmt.allocPrint(alloc, "Bus {}\nDev {}\n iface {}", .{ self.bus, self.dev, self.port }),
            else => unreachable,
        };
        return;
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

            const newGraphNode = try graph.newNode(child.device.getName());
            try graph.newEdge(parentGraphNode, newGraphNode);

            if (childNode.child != null) {
                try exportDotRecursive(child, graph, newGraphNode);
            }

            nextChildNode = childNode.next;
        }
    }
};
