// Types

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn TreeNode(T: type) type {
    return struct {
        const Self = @This();

        next: ?*Self = null,
        prev: ?*Self = null,
        child: ?*Self = null,

        childCount: usize = 0, // Only used for checking

        val: T,

        const init = single; // Alternate name
        pub fn single(val: T) Self {
            return .{
                .val = val,
            };
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

        pub fn len(self: Self) usize {
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

const TestTreeNode = TreeNode(u8);

test "Create tree node" {
    const root: TestTreeNode = .init(0);

    try std.testing.expectEqual(0, root.val);
    try std.testing.expectEqual(0, root.len());
}

test "Add children to node" {
    var root: TestTreeNode = .init(1);
    var c0: TestTreeNode = .init(13);
    var c1: TestTreeNode = .init(255);

    try std.testing.expectEqual(1, root.val);

    root.attachItem(&c0);
    try std.testing.expectEqual(1, root.len());
    try std.testing.expectEqual(c0.val, root.getChild(0).?.val);

    root.attachItem(&c1);
    try std.testing.expectEqual(2, root.len());
    try std.testing.expectEqual(c0.val, root.getChild(0).?.val);
    try std.testing.expectEqual(c1.val, root.getChild(1).?.val);

    // Recursive
    var c1c0: TestTreeNode = .init(20);

    root.getChild(1).?.attachItem(&c1c0);
    try std.testing.expectEqual(1, root.getChild(1).?.len());
    try std.testing.expectEqual(20, root.getChild(1).?.getChild(0).?.val);
}

test "Remove children from node" {
    var root: TestTreeNode = .init(1);
    var c0: TestTreeNode = .init(13);
    var c1: TestTreeNode = .init(255);
    var c1c0: TestTreeNode = .init(20);

    root.attachItem(&c0);
    root.attachItem(&c1);
    root.getChild(1).?.attachItem(&c1c0);

    try std.testing.expectEqual(2, root.len());

    const p1 = root.detachItem(0).?;
    try std.testing.expectEqual(1, root.len());
    try std.testing.expectEqual(c0.val, p1.val);

    const p2 = root.detachItem(0).?;
    try std.testing.expectEqual(0, root.len());
    try std.testing.expectEqual(c1.val, p2.val);
    try std.testing.expectEqual(1, p2.len());
    try std.testing.expectEqual(c1c0.val, p2.getChild(0).?.val);
}
