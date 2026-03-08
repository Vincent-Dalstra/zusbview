// Graphciz .dot files

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const GraphError = error{
    NameConflict,
};

pub const Graph = struct {
    directed: bool = true,

    arena: std.heap.ArenaAllocator = undefined,
    aalloc: Allocator = undefined,

    name: []const u8 = undefined,

    // Todo: Use a data structure which can be added to without invalidating existing nodes/edges!
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    clusters: std.ArrayList(Cluster) = .empty,

    pub fn init(self: *Graph, gpa: Allocator, name: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(gpa); // Must use an arena allocator!
        self.aalloc = self.arena.allocator();

        self.name = try self.aalloc.dupe(u8, name);

        // temporary fix; use a data structure that doesn't invalidate existing nodes/edges!
        try self.nodes.ensureTotalCapacityPrecise(self.aalloc, 1024);
        try self.edges.ensureTotalCapacityPrecise(self.aalloc, 1024);

        assert(self.nodes.items.len == 0);
        assert(self.edges.items.len == 0);
    }

    pub fn deinit(self: *Graph) void {
        self.arena.deinit(); // All together now!
    }

    pub fn newNode(self: *Graph, name: []const u8) !*Node {
        const new = try self.nodes.addOne(self.aalloc);
        new.* = .{
            .name = try self.aalloc.dupe(u8, name),
        };
        return new;
    }

    pub fn findNode(self: *Graph, name: []const u8) ?*Node {
        for (self.nodes.items) |*node| {
            if (std.mem.eql(u8, node.name, name)) {
                return node;
            }
        }
        return null;
    }

    pub fn hasNode(self: *Graph, name: []const u8) bool {
        return (self.findNode(name) != null);
    }

    pub fn newEdge(self: *Graph, src: *Node, dst: *Node) !void {
        const new: Edge = .{
            .src = src,
            .dst = dst,
        };
        try self.edges.append(self.aalloc, new);
    }

    pub fn countEdge(self: *Graph, src: *Node, dst: *Node) usize {
        var count: usize = 0;
        for (self.edges.items) |edge| {
            if (edge.src == src and edge.dst == dst) {
                count += 1;
            } else if (!self.directed and edge.src == dst and edge.dst == src) {
                count += 1;
            }
        }
        return count;
    }

    pub fn hasEdge(self: *Graph, src: *Node, dst: *Node) bool {
        return (self.countEdge(src, dst) > 0);
    }

    pub fn newCluster(self: *Graph, name: []const u8) !*Cluster {
        const new = try self.clusters.addOne(self.aalloc);
        new.* = .{
            .name = try self.aalloc.dupe(u8, name),
            .aalloc = self.aalloc,
        };
        return new;
    }

    pub fn findCluster(self: *Graph, name: []const u8) ?*Cluster {
        for (self.clusters.items) |*cluster| {
            if (std.mem.eql(u8, cluster.name, name)) {
                return cluster;
            }
        }
        return null;
    }

    pub fn hasCluster(self: *Graph, name: []const u8) bool {
        return (self.findCluster(name) != null);
    }

    pub fn print(self: Graph, writer: *std.io.Writer) !void {
        try writer.print(
            "{s} \"{s}\" {{\n", // escaped '{'
            .{
                if (self.directed) "digraph" else "graph",
                self.name,
            },
        );

        for (self.clusters.items) |cluster| {
            try cluster.print(writer);
        }

        for (self.nodes.items) |node| {
            try writer.print("\"{s}\"\n", .{node.name});
        }
        for (self.edges.items) |edge| {
            try writer.print(
                "\"{s}\" {s} \"{s}\"\n",
                .{
                    edge.src.name,
                    if (self.directed) "->" else "--",
                    edge.dst.name,
                },
            );
        }
        try writer.print("}}\n", .{}); // escaped '}'
        try writer.printAsciiChar(0, .{});
    }

    pub const Node = struct {
        name: []const u8,
    };

    pub const Edge = struct {
        src: *Node,
        dst: *Node,
    };

    // Todo: rename to 'subgraph'
    pub const Cluster = struct {
        name: []const u8,
        aalloc: Allocator, // same allocator as parent graph

        nodes: std.ArrayList(*Node) = .empty,

        pub fn addNode(self: *Cluster, node: *Node) !void {
            try self.nodes.append(self.aalloc, node);
        }

        pub fn print(self: Cluster, writer: *std.io.Writer) !void {
            try writer.print(
                "{s} \"{s}\" {{\n", // escaped '{'
                .{
                    "subgraph",
                    self.name,
                },
            );
            try writer.print(
                "{s}=\"{s}\"\n",
                .{
                    "label",
                    "\\G", // graphviz programs interpret \G to mean the graphs ID (name)'
                },
            );
            for (self.nodes.items) |node| {
                try writer.print("\"{s}\"\n", .{node.name});
            }
            try writer.print("}}\n", .{}); // escaped '}'
        }
    };
};

var testAlloc = std.testing.allocator;

test "export" {
    var graph: Graph = .{};
    try graph.init(testAlloc, "testGraph");
    defer graph.deinit();

    _ = try graph.newNode("a");
    _ = try graph.newNode("b");
    _ = try graph.newNode("c");

    const a = graph.findNode("a") orelse unreachable;
    const b = graph.findNode("b") orelse unreachable;
    const c = graph.findNode("c") orelse unreachable;

    try graph.newEdge(a, b);
    try graph.newEdge(a, c);
    try graph.newEdge(b, c);

    const buf: []u8 = try testAlloc.alloc(u8, (1024));
    defer testAlloc.free(buf);
    var writer = std.io.Writer.fixed(buf);

    try graph.print(&writer);
    try writer.flush();

    const written = std.mem.sliceTo(buf, 0);

    const expected =
        \\digraph "testGraph" {
        \\"a"
        \\"b"
        \\"c"
        \\"a" -> "b"
        \\"a" -> "c"
        \\"b" -> "c"
        \\}
        \\
    ;

    try std.testing.expectEqualStrings(expected, written);
}

test "export clusters" {
    var graph: Graph = .{};
    try graph.init(testAlloc, "testGraph");
    defer graph.deinit();

    _ = try graph.newNode("a");
    _ = try graph.newNode("b");
    _ = try graph.newNode("c");

    const a = graph.findNode("a") orelse unreachable;
    const b = graph.findNode("b") orelse unreachable;
    const c = graph.findNode("c") orelse unreachable;

    try graph.newEdge(a, b);
    try graph.newEdge(a, c);
    try graph.newEdge(b, c);

    _ = try graph.newCluster("cluster_abba");
    const abba = graph.findCluster("cluster_abba").?;

    try graph.addNodeToCluster(abba, a);
    try graph.addNodeToCluster(abba, b);

    const buf: []u8 = try testAlloc.alloc(u8, (1024));
    defer testAlloc.free(buf);
    var writer = std.io.Writer.fixed(buf);

    try graph.print(&writer);
    try writer.flush();

    const written = std.mem.sliceTo(buf, 0);

    const expected =
        \\digraph "testGraph" {
        \\subgraph "cluster_abba" {
        \\label="\G"
        \\"a"
        \\"b"
        \\}
        \\"a"
        \\"b"
        \\"c"
        \\"a" -> "b"
        \\"a" -> "c"
        \\"b" -> "c"
        \\}
        \\
    ;

    try std.testing.expectEqualStrings(expected, written);
}
