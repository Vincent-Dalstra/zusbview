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

pub fn TreeNode(T: type) type {
    return struct {
        const Self = @This();

        parent: ?*Self = null,
        next: ?*Self = null,
        prev: ?*Self = null,
        child: ?*Self = null,

        value: T,

        pub fn single(val: T) Self {
            return .{
                .value = val,
            };
        }

        pub fn addItem(self: *Self, item: *Self) void {
            assert(item.parent == null); // Must not already have a parent!
            assert(item.next == null);
            assert(item.prev == null);

            if (self.child) |child| {
                // append to the end of the list
                assert(child.prev);
                child.prev.?.suffix_object(item);
                self.child.?.prev = item;
            } else {
                // list is empty; start a new list
                self.child = item;
                item.prev = item;
                item.next = null;
            }
        }

        fn suffix_object(prev: *Self, item: *Self) void {
            prev.next = item;
            item.prev = prev;
        }
    };
}
