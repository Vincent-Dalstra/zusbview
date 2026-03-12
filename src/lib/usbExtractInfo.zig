const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const usbTypes = @import("../root.zig").usbTypes;

const usb_max_tiers = usbTypes.usb_max_tiers;

const UsbObjectInfo = struct {
    parsed: struct {
        id: usbTypes.HubOrEndPointIdentifier, // Determined from the 'directory name'
        speed: ?usbTypes.SpeedClass = null,
        serial: ?usbTypes.PciBdfNumber = null,
        devnum: ?u7 = null,
        maxchild: ?u8 = null,
    },
    inferred: struct {
        type: usbTypes.AnyObjectType,
    } = undefined,

    pub fn infer(self: UsbObjectInfo) UsbObjectInfo {
        var ret = self;
        ret.inferred = .{
            .type = self.parsed.id.type orelse if (self.parsed.maxchild == 0) .device else .hub,
        };
        ret.parsed.id.type = ret.inferred.type; // Reapply to the id, so its consistent

        return ret;
    }
};

pub fn usbExtractInfo(dirname: []const u8, dir: std.fs.Dir) !UsbObjectInfo {
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
        std.debug.print("{s}/{s} {any}\n", .{ dirname, entry2.name, entry2.kind });
        if (std.mem.eql(u8, "speed", entry2.name)) {
            assert(entry2.kind == .file);

            const raw_data = dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                std.debug.print("{any}\n", .{err});
                continue;
            };
            defer alloc.free(raw_data);

            // On linux at least, this file ends with a newline, and parseInt() doesn't like that
            const data = std.mem.trimEnd(u8, raw_data, "\r\n");

            obj.parsed.speed = try .fromStringMbps(data);
            std.debug.print("speed = {}\n", .{obj.parsed.speed.?.inMbps()});
        } else if (std.mem.eql(u8, "serial", entry2.name)) {
            assert(entry2.kind == .file);

            const raw_data = dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                std.debug.print("{any}\n", .{err});
                continue;
            };
            defer alloc.free(raw_data);

            // On linux at least, this file ends with a newline, and parseInt() doesn't like that
            const data = std.mem.trimEnd(u8, raw_data, "\r\n");

            std.debug.print("dirname={s}\nserial={s}", .{ dirname, data });

            // If it's a root hub, this will be a PCI number
            if (obj.parsed.id.type == .root_hub) {
                var temp: usbTypes.PciBdfNumber = undefined;
                @memcpy(temp.str[0..data.len], data);
                obj.parsed.serial = temp;
            }
        } else if (std.mem.eql(u8, "devnum", entry2.name)) {
            std.debug.print("{s}/{s} {any}\n", .{ dirname, entry2.name, entry2.kind });
            assert(entry2.kind == .file);

            const raw_data = dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                std.debug.print("{any}\n", .{err});
                continue;
            };
            defer alloc.free(raw_data);

            // On linux at least, this file ends with a newline, and parseInt() doesn't like that
            const data = std.mem.trimEnd(u8, raw_data, "\r\n");

            obj.parsed.devnum = try std.fmt.parseUnsigned(u7, data, 10);
        } else if (std.mem.eql(u8, "maxchild", entry2.name)) {
            std.debug.print("{s}/{s} {any}\n", .{ dirname, entry2.name, entry2.kind });
            assert(entry2.kind == .file);

            const raw_data = dir.readFileAlloc(alloc, entry2.name, 100) catch |err| {
                std.debug.print("{any}\n", .{err});
                continue;
            };
            defer alloc.free(raw_data);
            // On linux at least, this file ends with a newline, and parseInt() doesn't like that
            const data = std.mem.trimEnd(u8, raw_data, "\r\n");

            obj.parsed.maxchild = try std.fmt.parseUnsigned(u8, data, 10);
        }
    }

    // Devices and Hubs are ambiguous, so we need to infer them.
    obj = obj.infer();

    // Checks
    // switch (obj.inferred.type) {
    //     .root_hub => {
    //         assert(obj.parsed.serial != null);
    //     },
    //     .hub => {
    //         assert(obj.parsed.devnum.? > 0);
    //         assert(obj.parsed.maxchild.? > 0);
    //     },
    //     .device => {
    //         assert(obj.parsed.devnum.? != 0);
    //     },
    // }

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
