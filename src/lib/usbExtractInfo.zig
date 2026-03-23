const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const usbTypes = @import("../root.zig").usbTypes;

const usb_max_tiers = usbTypes.usb_max_tiers;

pub const UsbObjectInfo = struct {
    parsed: struct {
        id: usbTypes.HubOrEndPointIdentifier, // Determined from the 'directory name'
        speed: ?usbTypes.SpeedClass = null,
        serial: ?usbTypes.PciBdfNumber = null,
        devnum: ?u7 = null,
        maxchild: ?u8 = null,

        manufacturer: ?[]u8 = null,
        product: ?[]u8 = null,
    },
    inferred: struct {
        type: usbTypes.AnyObjectType,
    } = undefined,

    pub fn infer(self: UsbObjectInfo) UsbObjectInfo {
        var ret = self;
        ret.inferred = .{
            .type = self.parsed.id.id_type().infer() orelse if (self.parsed.maxchild == 0) .device else .hub,
        };

        return ret;
    }

    /// Creates the same names as found in  '/sys/bus/usb/devices'
    pub fn format(self: UsbObjectInfo, writer: *std.io.Writer) !void {
        try writer.print("{f}\n", .{self.parsed.id});
        if (self.parsed.devnum) |devnum| try writer.print("{s} = {}\n", .{ "devnum", devnum });
        try writer.print("{s} = {f}\n", .{ "type", self.inferred.type });
        if (self.parsed.maxchild) |maxchild| try writer.print("{s} = {}\n", .{ "maxchild", maxchild });
        if (self.parsed.speed) |speed| try writer.print("{s} = {}\n", .{ "speed", speed });
        if (self.parsed.manufacturer) |manufacturer| try writer.print("{s} = {s}\n", .{ "manufacturer", manufacturer });
        if (self.parsed.product) |product| try writer.print("{s} = {s}\n", .{ "product", product });

        writer.undo(1); // Remove last \n
    }
};

pub fn usbExtractInfo(dirname: []const u8, dir: std.fs.Dir, string_alloc: Allocator) !UsbObjectInfo {
    var alloc_buffer: [128]u8 = undefined; // Should be more than sufficient
    var buf_allocator: std.heap.FixedBufferAllocator = .init(&alloc_buffer);
    const alloc = buf_allocator.allocator();

    var obj: UsbObjectInfo = .{
        .parsed = .{
            .id = undefined,
        },
    };

    obj.parsed.id = try .fromStr(dirname);

    // Check that it converts back to the same string
    // const dev_str = try std.fmt.allocPrint(alloc, "{f}", .{obj.parsed.id});
    // assert(std.mem.eql(u8, dirname, dev_str));
    // alloc.free(dev_str);

    var dir_it = dir.iterateAssumeFirstIteration();
    while (try dir_it.next()) |entry2| {
        if (entry2.kind != .file) {
            continue;
        }

        std.debug.print("{s}/{s} {any}\n", .{ dirname, entry2.name, entry2.kind });
        var raw_data: ?[]u8 = null;
        defer if (raw_data) |p| alloc.free(p);
        if (entry2.kind == .file) {
            raw_data = dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                std.debug.print("{any}\n", .{err});
                continue;
            };
        }
        // On linux at least, the files ends with a newline, and parseInt() doesn't like that
        const data = if (raw_data) |d| std.mem.trimEnd(u8, d, "\r\n") else null;

        if (std.mem.eql(u8, "speed", entry2.name)) {
            obj.parsed.speed = try .fromStringMbps(data.?);
            std.debug.print("speed = {}\n", .{obj.parsed.speed.?.inMbps()});
        } else if (std.mem.eql(u8, "serial", entry2.name)) {
            // If it's a root hub, this will be a PCI number
            if (obj.parsed.id.id_type() == .root_hub) {
                var temp: usbTypes.PciBdfNumber = undefined;
                @memcpy(temp.str[0..data.?.len], data.?);
                obj.parsed.serial = temp;
            }
        } else if (std.mem.eql(u8, "devnum", entry2.name)) {
            std.debug.print("{s}/{s} {any}\n", .{ dirname, entry2.name, entry2.kind });
            obj.parsed.devnum = try std.fmt.parseUnsigned(u7, data.?, 10);
        } else if (std.mem.eql(u8, "maxchild", entry2.name)) {
            std.debug.print("{s}/{s} {any}\n", .{ dirname, entry2.name, entry2.kind });
            obj.parsed.maxchild = try std.fmt.parseUnsigned(u8, data.?, 10);
        } else if (std.mem.eql(u8, "manufacturer", entry2.name)) {
            obj.parsed.manufacturer = try string_alloc.dupe(u8, data.?);
        } else if (std.mem.eql(u8, "product", entry2.name)) {
            obj.parsed.product = try string_alloc.dupe(u8, data.?);
        }
    }

    // Devices and Hubs are ambiguous, so we need to infer them.
    obj = obj.infer();

    return obj;
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
