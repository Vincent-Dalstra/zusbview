// Types

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const usb_max_tiers = 7; // Tier 1 = root hub. other hubs are tier 2-6, devices are tier 1-7;

const DeviceType = enum {
    not_recognised,
    root_hub,
    hub,
    device,
};

pub const Device = struct {
    type: DeviceType,
};

pub const DeviceTreeNode = struct {
    // parent:
};
