// Types

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const LinkedTree = @This();

/// This struct contains only pointers and not any data payload. The
/// intended usage is to embed it intrusively into another data structure and
/// access the data with `@fieldParentPtr`.
pub fn Node() type {
    return struct {
        const Self = @This();

        next: ?*Self = null,
        prev: ?*Self = null,
        child: ?*Self = null,

        childCount: usize = 0, // Only used for checking

        const init = single; // Alternate name
        pub fn single() Self {
            return .{};
        }

        pub fn attachItem(self: *Self, item: *Self) void {
            assert(item.prev == null); // Must not already have a parent!
            assert(item.next == null);

            if (self.child) |child| {
                // append to the end of the list
                assert(child.prev != null);
                child.prev.?.suffix_object(item);
                // self.child.?.prev = item;
                child.prev = item;
            } else {
                // list is empty; start a new list
                self.child = item;
                item.prev = item;
                item.next = null;
            }

            self.childCount += 1;
        }

        fn suffix_object(prev: *Self, item: *Self) void {
            prev.next = item;
            item.prev = prev;
        }

        pub fn getChild(self: *Self, index: usize) ?*Self {
            var child = self.child;
            var count: usize = 0;
            while (count < index) {
                child = child.?.next;
                count += 1;
            }
            return child.?;
        }

        pub fn detachItem(self: *Self, index: usize) ?*Self {
            const child = self.getChild(index) orelse return null;

            return self.detachItemViaPointer(child);
        }

        pub fn detachItemViaPointer(parent: *Self, item: *Self) *Self {
            assert(item.prev != null); // Children always have 'prev' set
            assert(parent.childCount > 0); // Check internal counter

            if (item.prev == item) {
                // Only child

                // Sanity check existing links
                assert(item.next == null);

                parent.child = null;
            } else if (item.next == null) {
                // last item
                var firstChild = parent.child.?;
                var newLast = item.prev.?;

                // Sanity check existing links
                assert(firstChild.prev == item);
                assert(newLast.next == item);

                firstChild.prev = newLast;
                newLast.next = null;
            } else if (parent.child.? == item) {
                // first item
                var newFirst = item.next.?;
                const lastChild = item.prev.?;

                // Sanity check existing links
                assert(newFirst.prev == item);
                assert(lastChild.next == null);

                parent.child = newFirst;
                newFirst.prev = lastChild;
            } else {
                // somewhere in the middle
                var prev = item.prev.?;
                var next = item.next.?;

                // Sanity check existing links
                assert(prev.next == item);
                assert(next.prev == item);

                prev.next = next;
                next.prev = prev;
            }

            assert(parent.childCount > 0); // Check against internal counter
            parent.childCount -= 1;

            // Clear item's references to the parent tree
            item.prev = null;
            item.next = null;

            return item;
        }

        const len = countChildren; // Alternate name
        pub fn countChildren(self: Self) usize {
            var next = self.child;

            var count: usize = 0;
            while (next) |child| {
                count += 1;
                next = child.next;
            }

            assert(count == self.childCount); // Check against internal counter

            return count;
        }
    };
}

const LinkedList = std.SinglyLinkedList;

const L = struct {
    data: u32,
    node: LinkedTree.Node() = .{},
};

test "Create tree node" {
    var root: L = .{ .data = 99 };

    try testing.expectEqual(99, root.data);
    try testing.expectEqual(0, root.node.len());
}

test "Add children to node" {
    var root: L = .{ .data = 1 };
    var c0: L = .{ .data = 13 };
    var c1: L = .{ .data = 255 };
    try testing.expectEqual(1, root.data);

    root.node.attachItem(&c0.node);
    try testing.expectEqual(1, root.node.len());
    try testing.expectEqual(&c0.node, root.node.getChild(0).?);

    root.node.attachItem(&c1.node);
    try testing.expectEqual(2, root.node.len());
    try testing.expectEqual(&c0.node, root.node.getChild(0).?);
    try testing.expectEqual(&c1.node, root.node.getChild(1).?);

    // Recursive
    var c1c0: L = .{ .data = 20 };

    root.node.getChild(1).?.attachItem(&c1c0.node);
    try testing.expectEqual(1, root.node.getChild(1).?.len());
    try testing.expectEqual(&c1c0.node, root.node.getChild(1).?.getChild(0).?);

    // Access host structure using @fieldParentPtr
    const l: *L = @fieldParentPtr("node", root.node.getChild(1).?.getChild(0).?);
    try testing.expectEqual(c1c0.data, l.data);
}

test "Remove children from node" {
    var root: L = .{ .data = 1 };
    var c0: L = .{ .data = 13 };
    var c1: L = .{ .data = 255 };
    var c1c0: L = .{ .data = 20 };

    root.node.attachItem(&c0.node);
    root.node.attachItem(&c1.node);
    root.node.getChild(1).?.attachItem(&c1c0.node);

    try testing.expectEqual(2, root.node.len());

    const p1 = root.node.detachItem(0).?;
    try testing.expectEqual(1, root.node.len());
    try testing.expectEqual(&c0.node, p1);

    const p2 = root.node.detachItem(0).?;
    try testing.expectEqual(0, root.node.len());
    try testing.expectEqual(&c1.node, p2);
    try testing.expectEqual(1, p2.len());
    try testing.expectEqual(&c1c0.node, p2.getChild(0).?);
}
