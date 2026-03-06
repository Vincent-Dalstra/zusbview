// Types

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const LinkedTree = @import("LinkedTree.zig");

const graphviz = @import("graphviz.zig");

pub const usb_max_tiers = 7; // Tier 1 = root hub. other hubs are tier 2-6, devices are tier 1-7;

// Guaranteed unique across, so you can key a map from this
pub const UniqueDeviceId = struct {
    bus_num: u16,
    dev_num: DeviceNum,
};

pub const DeviceNum = u7;

pub const DeviceType = enum {
    root, // Dummy item to make the tree work

    not_recognised,
    root_hub,
    hub,
    // device,
    // iface,
    endpoint,
};

pub const AnyObject = struct {
    id: HubOrEndPointIdentifier,
    obj: AnyObjectEnum,
};

pub const AnyObjectType = enum {
    root_hub,
    hub,
    device,
    endpoint,
};

pub const AnyObjectEnum = union(AnyObjectType) {
    root_hub: RootHub,
    hub: Hub,
    device: Device,
    endpoint: Endpoint,
};

pub const PciBdfNumber = struct {
    // bus: u8,
    // device: u5,
    // function: u3,
    str: [12]u8, // 0000:00:0

    pub fn eql(a: PciBdfNumber, b: PciBdfNumber) bool {
        return std.mem.eql(u8, a, b);
    }
};

pub const RootHub = struct {
    id: HubOrEndPointIdentifier,

    speed: ?SpeedClass,
    serial: ?PciBdfNumber,

    devnum: u7, // Should always be 1, for a root hub
};

pub const Hub = struct {
    id: HubOrEndPointIdentifier,

    speed: ?SpeedClass,
    devnum: u7,
};

pub const Device = struct {
    id: HubOrEndPointIdentifier,

    speed: ?SpeedClass,
};

pub const Endpoint = struct {
    id: HubOrEndPointIdentifier,

    speed: ?SpeedClass,
};

// Value-compatible with libusb
pub const SpeedClass = enum(c_int) {
    UNKNOWN = 0, // For compatability; try to use null's and optionals instead
    LOW = 1,
    FULL = 2,
    HIGH = 3,
    SUPER = 4,
    SUPER_PLUS = 5,
    SUPER_PLUS_X2 = 6,

    pub fn inMbps(self: SpeedClass) u32 {
        return switch (self) {
            .LOW => 1, // Actually 1.5 Mbps, but general convention is to represent it as '1'
            .FULL => 12,
            .HIGH => 480,
            .SUPER => 5 * 1000,
            .SUPER_PLUS => 10 * 1000,
            .SUPER_PLUS_X2 => 20 * 1000,
            else => unreachable,
        };
    }
    pub fn fromStringMbps(str: []const u8) !?SpeedClass {
        if (str.len == 0) return null;
        const mbps = try std.fmt.parseUnsigned(u32, str, 10);
        return switch (mbps) {
            1 => .LOW,
            12 => .FULL,
            480 => .HIGH,
            5 * 1000 => .SUPER,
            10 * 1000 => .SUPER_PLUS,
            20 * 1000 => .SUPER_PLUS_X2,
            else => null,
        };
    }
};

pub const HubOrEndPointIdentifier = struct {
    type: AnyObjectType = undefined,

    bus: u8 = undefined,
    // See fn ports(), which returns these two as a slice for convenience
    ports_buffer: [7]u8 = [_]u8{0} ** 7,
    ports_len: usize = 0,

    iface: u8 = undefined,
    endpoint: u8 = undefined,

    pub fn ports(self: *const HubOrEndPointIdentifier) []const u8 {
        return self.ports_buffer[0..self.ports_len];
    }

    pub fn parent(self: HubOrEndPointIdentifier) ?HubOrEndPointIdentifier {
        switch (self.type) {
            .root_hub => return null,
            .hub => {
                assert(self.ports_len > 0);
                if (self.ports_len == 1) {
                    return .{
                        .type = .root_hub,
                        .bus = self.bus,
                    };
                } else {
                    var parent_object = self;
                    parent_object.ports_buffer[self.ports_len - 1] = 0;
                    parent_object.ports_len -= 1;
                    return parent_object;
                }
            },
            .endpoint => {
                return .{
                    .type = .hub,
                    .bus = self.bus,
                    .ports_buffer = self.ports_buffer,
                    .ports_len = self.ports_len,
                };
            },
            else => unreachable,
        }
    }

    /// Creates the same names as found in  '/sys/bus/usb/devices'
    pub fn format(self: HubOrEndPointIdentifier, writer: *std.io.Writer) !void {
        if (self.type == .root_hub) {
            try writer.print("usb{}", .{self.bus});
            return;
        }

        // Bus and first port always exist, separated by a '-'
        try writer.print("{}", .{self.bus});
        try writer.print("-{}", .{self.ports()[0]});

        for (self.ports()[1..]) |p| {
            try writer.print(".{}", .{p});
        }

        if (self.type == .hub) {
            return;
        }

        if (self.type == .endpoint) {
            try writer.print(":{}.{}", .{ self.iface, self.endpoint });
        }
    }

    pub fn fromStr(str: []const u8) !HubOrEndPointIdentifier {
        var dev: HubOrEndPointIdentifier = .{};
        if (std.mem.eql(u8, str[0..3], "usb")) {
            dev.type = .root_hub;
            dev.bus = try std.fmt.parseInt(u8, str[3..], 10);
            return dev;
        } else {
            const pre_semicolon = std.mem.sliceTo(str, ':');

            {
                var slice = pre_semicolon;

                // Always starts with bus number
                slice = try parseIntUpTo(slice, '-', u8, &dev.bus);
                slice = skipString(slice, "-").?;

                var depth: u8 = 0;
                slice = try parseIntUpTo(slice, '.', u8, &dev.ports_buffer[depth]);
                depth += 1;
                while (true) {
                    slice = skipString(slice, ".") orelse break;
                    slice = try parseIntUpTo(slice, '.', u8, &dev.ports_buffer[depth]);
                    depth += 1;
                }
                dev.ports_len = depth;
                // std.debug.print("dev.ports={any}\n", .{dev.ports()});
            }

            if (pre_semicolon.len == str.len) {
                // There was no semicolon
                dev.type = .hub;
            } else {
                dev.type = .endpoint;

                const post_semicolon = str[(pre_semicolon.len + 1)..];
                assert(post_semicolon.len >= 3);

                var slice = post_semicolon;

                slice = try parseIntUpTo(slice, '.', u8, &dev.iface);
                slice = skipString(slice, ".").?;
                slice = try parseIntUpTo(slice, 0, u8, &dev.endpoint);

                assert(slice.len == 0);
            }
            return dev;
        }
    }
};

pub const HubTree = struct {
    node: LinkedTree.Node = .{},

    id: UniqueDeviceId,

    pub fn newDevice(self: *HubTree, arena: Allocator, new: UniqueDeviceId) !*HubTree {
        const newNode = try arena.create(HubTree);
        newNode.* = .{
            .node = .{},
            .device = new,
        };
        self.node.attachItem(&newNode.node);

        return newNode;
    }

    pub fn exportDot(self: *HubTree, graph: *graphviz.Graph) !void {
        const rootNode = try graph.newNode("root");

        try exportDotRecursive(self, graph, rootNode);
    }

    fn exportDotRecursive(parentDev: *HubTree, graph: *graphviz.Graph, parentGraphNode: *graphviz.Graph.Node) !void {
        var nextChildNode = parentDev.node.child;
        while (nextChildNode) |childNode| {
            const child: *HubTree = @fieldParentPtr("node", childNode);

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

fn skipString(slice: []const u8, expected: []const u8) ?[]const u8 {
    if (slice.len < expected.len) return null;

    if (std.mem.eql(u8, expected, slice[0..expected.len])) {
        return slice[expected.len..];
    } else {
        return null;
    }
}

fn parseIntUpTo(slice: []const u8, comptime end: u8, T: type, out: *T) ![]const u8 {
    const number_str = std.mem.sliceTo(slice, end);
    // std.debug.print("number_Str='{s}'\n", .{number_str});
    out.* = try std.fmt.parseUnsigned(T, number_str, 10);
    return slice[number_str.len..];
}
