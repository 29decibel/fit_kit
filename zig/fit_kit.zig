const std = @import("std");

const fit_epoch_offset = 631065600;

const FitError = error{
    InvalidHeader,
    InvalidDataSize,
    MissingDefinition,
    UnexpectedEof,
    UnsupportedBaseType,
};

const Endian = enum { little, big };

const BaseType = enum(u8) {
    enum_ = 0x00,
    sint8 = 0x01,
    uint8 = 0x02,
    sint16 = 0x83,
    uint16 = 0x84,
    sint32 = 0x85,
    uint32 = 0x86,
    string = 0x07,
    float32 = 0x88,
    float64 = 0x89,
    uint8z = 0x0a,
    uint16z = 0x8b,
    uint32z = 0x8c,
    byte = 0x0d,
    sint64 = 0x8e,
    uint64 = 0x8f,
    uint64z = 0x90,
};

const RawValue = union(enum) {
    signed: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,
    bytes: []const u8,
};

const JsonValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
};

const Field = struct {
    name: []const u8,
    units: []const u8,
    value: JsonValue,
};

const Record = struct {
    kind: []const u8,
    fields: std.ArrayList(Field),
};

const FieldDefinition = struct {
    number: u8,
    size: u8,
    base_type: BaseType,
};

const DeveloperFieldDefinition = struct {
    number: u8,
    size: u8,
    developer_data_index: u8,
};

const Definition = struct {
    endian: Endian,
    global_message_number: u16,
    fields: std.ArrayList(FieldDefinition),
    developer_fields: std.ArrayList(DeveloperFieldDefinition),
};

const DeveloperDescription = struct {
    field_name: []const u8,
    units: []const u8,
    scale: f64,
    offset: f64,
    base_type: BaseType,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: usize = 0,
    definitions: [16]?Definition = [_]?Definition{null} ** 16,
    developer_descriptions: std.AutoHashMap(u16, DeveloperDescription),
    records: std.ArrayList(Record),
    base_timestamp: i64 = 0,

    fn init(allocator: std.mem.Allocator, data: []const u8) Parser {
        return .{
            .allocator = allocator,
            .data = data,
            .developer_descriptions = std.AutoHashMap(u16, DeveloperDescription).init(allocator),
            .records = .empty,
        };
    }

    fn parse(self: *Parser) !void {
        if (self.data.len < 12) return FitError.InvalidHeader;
        const header_size = self.data[0];
        if (header_size != 12 and header_size != 14) return FitError.InvalidHeader;
        if (self.data.len < header_size) return FitError.InvalidHeader;
        if (!std.mem.eql(u8, self.data[8..12], ".FIT")) return FitError.InvalidHeader;

        const data_size = readInt(u32, self.data[4..8], .little);
        const data_start: usize = header_size;
        const data_end = data_start + @as(usize, data_size);
        if (data_end > self.data.len) return FitError.InvalidDataSize;

        self.offset = data_start;
        while (self.offset < data_end) {
            try self.parseMessage(data_end);
        }
    }

    fn parseMessage(self: *Parser, data_end: usize) !void {
        _ = data_end;
        const header = try self.readByte();

        if ((header & 0x80) != 0) {
            const local_number = (header >> 5) & 0x03;
            const time_offset = header & 0x1f;
            try self.parseDataMessage(local_number, time_offset);
            return;
        }

        const is_definition = (header & 0x40) != 0;
        const has_developer_data = (header & 0x20) != 0;
        const local_number = header & 0x0f;

        if (is_definition) {
            try self.parseDefinition(local_number, has_developer_data);
        } else {
            try self.parseDataMessage(local_number, null);
        }
    }

    fn parseDefinition(self: *Parser, local_number: u8, has_developer_data: bool) !void {
        _ = try self.readByte();
        const arch = try self.readByte();
        const endian: Endian = if (arch == 1) .big else .little;
        const global_message_number = try self.readIntAt(u16, endian);
        const field_count = try self.readByte();

        var fields: std.ArrayList(FieldDefinition) = .empty;
        for (0..field_count) |_| {
            const number = try self.readByte();
            const size = try self.readByte();
            const base_type_byte = (try self.readByte()) & 0x9f;
            const base_type = baseTypeFromByte(base_type_byte);
            try fields.append(self.allocator, .{ .number = number, .size = size, .base_type = base_type });
        }

        var developer_fields: std.ArrayList(DeveloperFieldDefinition) = .empty;
        if (has_developer_data) {
            const developer_field_count = try self.readByte();
            for (0..developer_field_count) |_| {
                try developer_fields.append(self.allocator, .{
                    .number = try self.readByte(),
                    .size = try self.readByte(),
                    .developer_data_index = try self.readByte(),
                });
            }
        }

        if (self.definitions[local_number]) |*old| {
            old.fields.deinit(self.allocator);
            old.developer_fields.deinit(self.allocator);
        }
        self.definitions[local_number] = .{
            .endian = endian,
            .global_message_number = global_message_number,
            .fields = fields,
            .developer_fields = developer_fields,
        };
    }

    fn parseDataMessage(self: *Parser, local_number: u8, compressed_time_offset: ?u8) !void {
        const definition = self.definitions[local_number] orelse return FitError.MissingDefinition;
        var raw_fields = std.AutoHashMap(u8, RawValue).init(self.allocator);
        defer raw_fields.deinit();

        for (definition.fields.items) |field_definition| {
            if (try self.readRawValue(field_definition.base_type, definition.endian, field_definition.size)) |value| {
                try raw_fields.put(field_definition.number, value);
            }
        }

        if (messageKind(definition.global_message_number) == null) {
            try self.skipDeveloperFields(&definition);
            return;
        }

        var record = Record{
            .kind = messageKind(definition.global_message_number).?,
            .fields = .empty,
        };

        try self.decodeKnownFields(definition.global_message_number, &raw_fields, &record);

        if (compressed_time_offset) |time_offset| {
            const timestamp = self.updateCompressedTimestamp(time_offset);
            try record.fields.append(self.allocator, .{
                .name = "timestamp",
                .units = "s",
                .value = .{ .int = timestamp },
            });
        }

        try self.decodeDeveloperFields(&definition, &record);
        if (definition.global_message_number == 206) try self.rememberDeveloperDescription(&record);
        try self.records.append(self.allocator, record);
    }

    fn skipDeveloperFields(self: *Parser, definition: *const Definition) !void {
        for (definition.developer_fields.items) |field_definition| {
            try self.skip(field_definition.size);
        }
    }

    fn decodeKnownFields(self: *Parser, msg: u16, raw_fields: *std.AutoHashMap(u8, RawValue), record: *Record) !void {
        for (0..256) |field_number_usize| {
            const field_number: u8 = @intCast(field_number_usize);
            if (fieldProfile(msg, field_number)) |profile| {
                const raw = raw_fields.get(field_number) orelse continue;
                const value = try self.convertValue(raw, profile);
                try record.fields.append(self.allocator, .{
                    .name = profile.name,
                    .units = profile.units,
                    .value = value,
                });

                if (msg == 20 and field_number == 253) {
                    self.base_timestamp = asInt(raw) orelse self.base_timestamp;
                }
            }
        }
    }

    fn decodeDeveloperFields(self: *Parser, definition: *const Definition, record: *Record) !void {
        for (definition.developer_fields.items) |field_definition| {
            const key = developerKey(field_definition.developer_data_index, field_definition.number);
            if (self.developer_descriptions.get(key)) |description| {
                if (try self.readRawValue(description.base_type, definition.endian, field_definition.size)) |raw| {
                    const profile = FieldProfile{
                        .name = description.field_name,
                        .units = description.units,
                        .scale = description.scale,
                        .offset = description.offset,
                        .kind = .number,
                    };
                    try record.fields.append(self.allocator, .{
                        .name = profile.name,
                        .units = profile.units,
                        .value = try self.convertValue(raw, profile),
                    });
                }
            } else {
                try self.skip(field_definition.size);
            }
        }
    }

    fn rememberDeveloperDescription(self: *Parser, record: *const Record) !void {
        var developer_data_index: ?u8 = null;
        var field_definition_number: ?u8 = null;
        var fit_base_type: ?BaseType = null;
        var field_name: []const u8 = "";
        var units: []const u8 = "";
        var scale: f64 = 1.0;
        var offset: f64 = 0.0;

        for (record.fields.items) |field| {
            if (std.mem.eql(u8, field.name, "developer_data_index")) developer_data_index = @intCast(jsonInt(field.value) orelse 0);
            if (std.mem.eql(u8, field.name, "field_definition_number")) field_definition_number = @intCast(jsonInt(field.value) orelse 0);
            if (std.mem.eql(u8, field.name, "fit_base_type_id")) {
                const raw_type: u8 = @intCast(jsonInt(field.value) orelse 0x0d);
                fit_base_type = baseTypeFromByte(raw_type & 0x9f);
            }
            if (std.mem.eql(u8, field.name, "field_name") and field.value == .string) field_name = field.value.string;
            if (std.mem.eql(u8, field.name, "units") and field.value == .string) units = field.value.string;
            if (std.mem.eql(u8, field.name, "scale")) scale = @floatFromInt(jsonInt(field.value) orelse 1);
            if (std.mem.eql(u8, field.name, "offset")) offset = @floatFromInt(jsonInt(field.value) orelse 0);
        }

        if (developer_data_index != null and field_definition_number != null and fit_base_type != null and field_name.len > 0) {
            try self.developer_descriptions.put(
                developerKey(developer_data_index.?, field_definition_number.?),
                .{
                    .field_name = field_name,
                    .units = units,
                    .scale = scale,
                    .offset = offset,
                    .base_type = fit_base_type.?,
                },
            );
        }
    }

    fn convertValue(self: *Parser, raw: RawValue, profile: FieldProfile) !JsonValue {
        _ = self;
        switch (profile.kind) {
            .timestamp => {
                const seconds = asInt(raw) orelse 0;
                return .{ .int = seconds + fit_epoch_offset };
            },
            .activity_type => {
                const value = asInt(raw) orelse 0;
                return .{ .string = activityTypeName(value) };
            },
            .number => {
                if (raw == .string) return .{ .string = raw.string };
                if (raw == .bytes) return .{ .string = "" };
                if (profile.scale != 1.0 or profile.offset != 0.0) {
                    const value = asFloat(raw) orelse 0.0;
                    return .{ .float = value / profile.scale - profile.offset };
                }
                return .{ .int = asInt(raw) orelse 0 };
            },
            .string => {
                if (raw == .string) return .{ .string = raw.string };
                return .{ .string = "" };
            },
        }
    }

    fn updateCompressedTimestamp(self: *Parser, offset: u8) i64 {
        const mask: i64 = 31;
        var value = @as(i64, offset) + (self.base_timestamp & ~mask);
        if (@as(i64, offset) < (self.base_timestamp & mask)) value += 32;
        self.base_timestamp = value;
        return value + fit_epoch_offset;
    }

    fn readRawValue(self: *Parser, base_type: BaseType, endian: Endian, size: u8) !?RawValue {
        if (base_type == .string) {
            const bytes = try self.readBytes(size);
            const nul = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
            return .{ .string = bytes[0..nul] };
        }

        const base_size = baseTypeSize(base_type);
        if (base_size == 0 or size % base_size != 0) {
            const bytes = try self.readBytes(size);
            return .{ .bytes = bytes };
        }

        const count = size / base_size;
        if (count != 1) {
            const bytes = try self.readBytes(size);
            return .{ .bytes = bytes };
        }

        return switch (base_type) {
            .enum_, .uint8 => blk: {
                const value = try self.readByte();
                break :blk if (value == 0xff) null else RawValue{ .unsigned = value };
            },
            .byte => RawValue{ .unsigned = try self.readByte() },
            .sint8 => blk: {
                const value = @as(i8, @bitCast(try self.readByte()));
                break :blk if (value == 0x7f) null else RawValue{ .signed = value };
            },
            .uint8z => blk: {
                const value = try self.readByte();
                break :blk if (value == 0) null else RawValue{ .unsigned = value };
            },
            .sint16 => blk: {
                const value = try self.readIntAt(i16, endian);
                break :blk if (value == 0x7fff) null else RawValue{ .signed = value };
            },
            .uint16 => blk: {
                const value = try self.readIntAt(u16, endian);
                break :blk if (value == 0xffff) null else RawValue{ .unsigned = value };
            },
            .uint16z => blk: {
                const value = try self.readIntAt(u16, endian);
                break :blk if (value == 0) null else RawValue{ .unsigned = value };
            },
            .sint32 => blk: {
                const value = try self.readIntAt(i32, endian);
                break :blk if (value == 0x7fffffff) null else RawValue{ .signed = value };
            },
            .uint32 => blk: {
                const value = try self.readIntAt(u32, endian);
                break :blk if (value == 0xffffffff) null else RawValue{ .unsigned = value };
            },
            .uint32z => blk: {
                const value = try self.readIntAt(u32, endian);
                break :blk if (value == 0) null else RawValue{ .unsigned = value };
            },
            .sint64 => blk: {
                const value = try self.readIntAt(i64, endian);
                break :blk if (value == 0x7fffffffffffffff) null else RawValue{ .signed = value };
            },
            .uint64 => blk: {
                const value = try self.readIntAt(u64, endian);
                break :blk if (value == 0xffffffffffffffff) null else RawValue{ .unsigned = value };
            },
            .uint64z => blk: {
                const value = try self.readIntAt(u64, endian);
                break :blk if (value == 0) null else RawValue{ .unsigned = value };
            },
            .float32 => RawValue{ .float = @floatCast(try self.readFloatAt(f32, endian)) },
            .float64 => RawValue{ .float = try self.readFloatAt(f64, endian) },
            .string => unreachable,
        };
    }

    fn readByte(self: *Parser) !u8 {
        if (self.offset >= self.data.len) return FitError.UnexpectedEof;
        const value = self.data[self.offset];
        self.offset += 1;
        return value;
    }

    fn readBytes(self: *Parser, len: usize) ![]const u8 {
        if (self.offset + len > self.data.len) return FitError.UnexpectedEof;
        const bytes = self.data[self.offset .. self.offset + len];
        self.offset += len;
        return bytes;
    }

    fn readIntAt(self: *Parser, comptime T: type, endian: Endian) !T {
        const bytes = try self.readBytes(@sizeOf(T));
        return readInt(T, bytes, endian);
    }

    fn readFloatAt(self: *Parser, comptime T: type, endian: Endian) !T {
        const UInt = if (T == f32) u32 else u64;
        const bits = try self.readIntAt(UInt, endian);
        return @bitCast(bits);
    }

    fn skip(self: *Parser, len: usize) !void {
        _ = try self.readBytes(len);
    }
};

const FieldKind = enum { number, string, timestamp, activity_type };

const FieldProfile = struct {
    name: []const u8,
    units: []const u8 = "",
    scale: f64 = 1.0,
    offset: f64 = 0.0,
    kind: FieldKind = .number,
};

fn messageKind(msg: u16) ?[]const u8 {
    return switch (msg) {
        0 => "file_id",
        18 => "session",
        19 => "lap",
        20 => "record",
        21 => "event",
        23 => "device_info",
        34 => "activity",
        206 => "field_description",
        207 => "developer_data_id",
        else => null,
    };
}

fn fieldProfile(msg: u16, field: u8) ?FieldProfile {
    return switch (msg) {
        20 => recordFieldProfile(field),
        206 => fieldDescriptionProfile(field),
        207 => developerDataIdProfile(field),
        else => genericFieldProfile(msg, field),
    };
}

fn recordFieldProfile(field: u8) ?FieldProfile {
    return switch (field) {
        0 => .{ .name = "position_lat", .units = "semicircles" },
        1 => .{ .name = "position_long", .units = "semicircles" },
        2 => .{ .name = "enhanced_altitude", .units = "m", .scale = 5.0, .offset = 500.0 },
        3 => .{ .name = "heart_rate", .units = "bpm" },
        4 => .{ .name = "cadence", .units = "rpm" },
        5 => .{ .name = "distance", .units = "m", .scale = 100.0 },
        6 => .{ .name = "enhanced_speed", .units = "m/s", .scale = 1000.0 },
        7 => .{ .name = "power", .units = "watts" },
        29 => .{ .name = "accumulated_power", .units = "watts" },
        42 => .{ .name = "activity_type", .kind = .activity_type },
        73 => .{ .name = "enhanced_speed", .units = "m/s", .scale = 1000.0 },
        78 => .{ .name = "enhanced_altitude", .units = "m", .scale = 5.0, .offset = 500.0 },
        85 => .{ .name = "step_length", .units = "mm", .scale = 10.0 },
        253 => .{ .name = "timestamp", .units = "s", .kind = .timestamp },
        else => null,
    };
}

fn fieldDescriptionProfile(field: u8) ?FieldProfile {
    return switch (field) {
        0 => .{ .name = "developer_data_index" },
        1 => .{ .name = "field_definition_number" },
        2 => .{ .name = "fit_base_type_id" },
        3 => .{ .name = "field_name", .kind = .string },
        6 => .{ .name = "scale" },
        7 => .{ .name = "offset" },
        8 => .{ .name = "units", .kind = .string },
        14 => .{ .name = "native_mesg_num" },
        15 => .{ .name = "native_field_num" },
        else => null,
    };
}

fn developerDataIdProfile(field: u8) ?FieldProfile {
    return switch (field) {
        0 => .{ .name = "developer_id" },
        1 => .{ .name = "application_id" },
        2 => .{ .name = "manufacturer_id" },
        3 => .{ .name = "developer_data_index" },
        4 => .{ .name = "application_version" },
        else => null,
    };
}

fn genericFieldProfile(msg: u16, field: u8) ?FieldProfile {
    if (field == 253) return .{ .name = "timestamp", .units = "s", .kind = .timestamp };

    return switch (msg) {
        18, 19 => switch (field) {
            5 => .{ .name = "sport" },
            7 => .{ .name = "total_elapsed_time", .units = "s", .scale = 1000.0 },
            8 => .{ .name = "total_timer_time", .units = "s", .scale = 1000.0 },
            9 => .{ .name = "total_distance", .units = "m", .scale = 100.0 },
            11 => .{ .name = "total_calories", .units = "kcal" },
            14 => .{ .name = "avg_speed", .units = "m/s", .scale = 1000.0 },
            15 => .{ .name = "max_speed", .units = "m/s", .scale = 1000.0 },
            16 => .{ .name = "avg_heart_rate", .units = "bpm" },
            17 => .{ .name = "max_heart_rate", .units = "bpm" },
            18 => .{ .name = "avg_cadence", .units = "rpm" },
            19 => .{ .name = "max_cadence", .units = "rpm" },
            20 => .{ .name = "avg_power", .units = "watts" },
            21 => .{ .name = "max_power", .units = "watts" },
            22 => .{ .name = "total_ascent", .units = "m" },
            23 => .{ .name = "total_descent", .units = "m" },
            else => null,
        },
        34 => switch (field) {
            0 => .{ .name = "total_timer_time", .units = "s", .scale = 1000.0 },
            1 => .{ .name = "num_sessions" },
            2 => .{ .name = "type", .kind = .activity_type },
            5 => .{ .name = "local_timestamp", .units = "s", .kind = .timestamp },
            else => null,
        },
        else => null,
    };
}

fn activityTypeName(value: i64) []const u8 {
    return switch (value) {
        0 => "generic",
        1 => "running",
        2 => "cycling",
        3 => "transition",
        4 => "fitness_equipment",
        5 => "swimming",
        6 => "walking",
        8 => "sedentary",
        254 => "all",
        else => "unknown",
    };
}

fn baseTypeSize(base_type: BaseType) u8 {
    return switch (base_type) {
        .enum_, .sint8, .uint8, .string, .uint8z, .byte => 1,
        .sint16, .uint16, .uint16z => 2,
        .sint32, .uint32, .float32, .uint32z => 4,
        .float64, .sint64, .uint64, .uint64z => 8,
    };
}

fn baseTypeFromByte(value: u8) BaseType {
    return switch (value) {
        0x00 => .enum_,
        0x01 => .sint8,
        0x02 => .uint8,
        0x83 => .sint16,
        0x84 => .uint16,
        0x85 => .sint32,
        0x86 => .uint32,
        0x07 => .string,
        0x88 => .float32,
        0x89 => .float64,
        0x0a => .uint8z,
        0x8b => .uint16z,
        0x8c => .uint32z,
        0x0d => .byte,
        0x8e => .sint64,
        0x8f => .uint64,
        0x90 => .uint64z,
        else => .byte,
    };
}

fn readInt(comptime T: type, bytes: []const u8, endian: Endian) T {
    return switch (endian) {
        .little => std.mem.readInt(T, bytes[0..@sizeOf(T)], .little),
        .big => std.mem.readInt(T, bytes[0..@sizeOf(T)], .big),
    };
}

fn asInt(value: RawValue) ?i64 {
    return switch (value) {
        .signed => |v| v,
        .unsigned => |v| @intCast(v),
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn asFloat(value: RawValue) ?f64 {
    return switch (value) {
        .signed => |v| @floatFromInt(v),
        .unsigned => |v| @floatFromInt(v),
        .float => |v| v,
        else => null,
    };
}

fn jsonInt(value: JsonValue) ?i64 {
    return switch (value) {
        .int => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn developerKey(developer_data_index: u8, field_number: u8) u16 {
    return (@as(u16, developer_data_index) << 8) | field_number;
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

fn writeJsonValue(writer: anytype, value: JsonValue) !void {
    switch (value) {
        .int => |v| try writer.print("{}", .{v}),
        .float => |v| try writer.print("{d}", .{v}),
        .string => |v| try writeJsonString(writer, v),
    }
}

fn writeRecordsJson(writer: anytype, records: []const Record) !void {
    try writer.writeAll("{\"records\":[");
    for (records, 0..) |record, record_index| {
        if (record_index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try writeJsonString(writer, record.kind);
        try writer.writeAll(",\"fields\":[");
        for (record.fields.items, 0..) |field, field_index| {
            if (field_index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try writeJsonString(writer, field.name);
            try writer.writeAll(",\"units\":");
            try writeJsonString(writer, field.units);
            try writer.writeAll(",\"value\":");
            try writeJsonValue(writer, field.value);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}\n");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const path = if (args.len > 1) args[1] else {
        std.debug.print("usage: fit_kit_zig <file.fit>\n", .{});
        return error.InvalidHeader;
    };

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024 * 256));
    defer allocator.free(data);

    var parser = Parser.init(allocator, data);
    try parser.parse();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try writeRecordsJson(stdout, parser.records.items);
    try stdout.flush();
}
