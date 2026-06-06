const std = @import("std");

const c = @cImport({
    @cInclude("ruby.h");
});

const VALUE = c.VALUE;
const Qnil: VALUE = 8;
const FIT_EPOCH_OFFSET: i64 = 631065600;

var fit_parse_result_class: VALUE = Qnil;

const BaseType = enum(u5) {
    enum_type = 0,
    sint8 = 1,
    uint8 = 2,
    sint16 = 3,
    uint16 = 4,
    sint32 = 5,
    uint32 = 6,
    string = 7,
    float32 = 8,
    float64 = 9,
    uint8z = 10,
    uint16z = 11,
    uint32z = 12,
    byte = 13,
    sint64 = 14,
    uint64 = 15,
    uint64z = 16,
};

const FieldDef = struct {
    number: u8,
    size: u8,
    base_type: BaseType,
};

const DeveloperFieldDef = struct {
    field_number: u8,
    size: u8,
    developer_data_index: u8,
};

const Definition = struct {
    global_message_number: u16,
    little_endian: bool,
    fields: std.ArrayList(FieldDef),
    developer_fields: std.ArrayList(DeveloperFieldDef),

    fn deinit(self: *Definition) void {
        self.fields.deinit();
        self.developer_fields.deinit();
    }
};

const Scalar = union(enum) {
    none,
    signed: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,

    fn toF64(self: Scalar) ?f64 {
        return switch (self) {
            .signed => |value| @floatFromInt(value),
            .unsigned => |value| @floatFromInt(value),
            .float => |value| value,
            else => null,
        };
    }

    fn toU64(self: Scalar) ?u64 {
        return switch (self) {
            .signed => |value| if (value >= 0) @intCast(value) else null,
            .unsigned => |value| value,
            .float => null,
            else => null,
        };
    }
};

const FieldInfo = struct {
    name: []const u8,
    units: []const u8 = "",
    scale: f64 = 1.0,
    offset: f64 = 0.0,
    date_time: bool = false,
    activity_type: bool = false,
    fit_base_type: bool = false,
};

const DeveloperDescription = struct {
    base_type: BaseType,
    name: []const u8,
    units: []const u8 = "",
    scale: f64 = 1.0,
    offset: f64 = 0.0,
};

const DeveloperDescriptionBuilder = struct {
    developer_data_index: ?u8 = null,
    field_definition_number: ?u8 = null,
    base_type: ?BaseType = null,
    name: ?[]const u8 = null,
    units: []const u8 = "",
    scale: f64 = 1.0,
    offset: f64 = 0.0,

    fn capture(self: *DeveloperDescriptionBuilder, field_number: u8, scalar: Scalar) void {
        switch (field_number) {
            0 => {
                if (scalar.toU64()) |value| self.developer_data_index = @intCast(value);
            },
            1 => {
                if (scalar.toU64()) |value| self.field_definition_number = @intCast(value);
            },
            2 => {
                if (scalar.toU64()) |value| self.base_type = baseTypeFromFitBaseTypeId(@intCast(value));
            },
            3 => switch (scalar) {
                .string => |value| self.name = value,
                else => {},
            },
            6 => {
                if (scalar.toF64()) |value| self.scale = value;
            },
            7 => {
                if (scalar.toF64()) |value| self.offset = value;
            },
            8 => switch (scalar) {
                .string => |value| self.units = value,
                else => {},
            },
            else => {},
        }
    }

    fn key(self: DeveloperDescriptionBuilder) ?u16 {
        const developer_data_index = self.developer_data_index orelse return null;
        const field_definition_number = self.field_definition_number orelse return null;
        return developerDescriptionKey(developer_data_index, field_definition_number);
    }

    fn description(self: DeveloperDescriptionBuilder) ?DeveloperDescription {
        const base_type = self.base_type orelse return null;
        return .{
            .base_type = base_type,
            .name = self.name orelse "unknown_developer_field",
            .units = self.units,
            .scale = self.scale,
            .offset = self.offset,
        };
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: usize = 0,
    end: usize = 0,
    definitions: [16]?Definition = [_]?Definition{null} ** 16,
    groups: [known_kinds.len]VALUE = [_]VALUE{Qnil} ** known_kinds.len,
    all_records: VALUE = Qnil,
    base_timestamp: i64 = 0,
    accumulators: std.AutoHashMap(u32, u64),
    developer_descriptions: std.AutoHashMap(u16, DeveloperDescription),

    fn init(allocator: std.mem.Allocator, data: []const u8) !Parser {
        var parser = Parser{
            .allocator = allocator,
            .data = data,
            .all_records = c.rb_ary_new(),
            .accumulators = std.AutoHashMap(u32, u64).init(allocator),
            .developer_descriptions = std.AutoHashMap(u16, DeveloperDescription).init(allocator),
        };
        try parser.readHeader();
        return parser;
    }

    fn deinit(self: *Parser) void {
        for (&self.definitions) |*definition| {
            if (definition.*) |*value| value.deinit();
        }
        self.accumulators.deinit();
        self.developer_descriptions.deinit();
    }

    fn parse(self: *Parser) !VALUE {
        while (self.offset < self.data.len) {
            while (self.offset < self.end) {
                const header = try self.readU8();
                if ((header & 0x80) != 0) {
                    try self.parseCompressedTimestampMessage(header);
                } else if ((header & 0x40) != 0) {
                    try self.parseDefinitionMessage(header);
                } else {
                    try self.parseDataMessage(header & 0x0f, null);
                }
            }

            if (self.offset + 2 > self.data.len) return error.InvalidFitData;
            self.offset += 2;
            if (self.offset < self.data.len) {
                self.resetFileState();
                try self.readHeader();
            }
        }

        const result = c.rb_obj_alloc(fit_parse_result_class);
        _ = c.rb_iv_set(result, "@records_hash", self.buildRecordsHash());
        _ = c.rb_iv_set(result, "@records", self.all_records);
        return result;
    }

    fn readHeader(self: *Parser) !void {
        if (self.offset + 12 > self.data.len) return error.InvalidFitHeader;
        const header_start = self.offset;
        const header_size = self.data[header_start];
        if (header_size != 12 and header_size != 14) return error.InvalidFitHeader;
        if (header_start + header_size + 2 > self.data.len) return error.InvalidFitHeader;
        if (!std.mem.eql(u8, self.data[header_start + 8 .. header_start + 12], ".FIT")) return error.InvalidFitHeader;

        const data_size = std.mem.readInt(u32, self.data[header_start + 4 ..][0..4], .little);
        self.offset = header_start + header_size;
        self.end = self.offset + @as(usize, data_size);
        if (self.end + 2 > self.data.len) return error.InvalidFitData;
    }

    fn resetFileState(self: *Parser) void {
        for (&self.definitions) |*definition| {
            if (definition.*) |*value| value.deinit();
            definition.* = null;
        }
        self.base_timestamp = 0;
        self.accumulators.clearRetainingCapacity();
        self.developer_descriptions.clearRetainingCapacity();
    }

    fn parseCompressedTimestampMessage(self: *Parser, header: u8) !void {
        const local_message_number = (header >> 5) & 0x03;
        const time_offset = header & 0x1f;
        try self.parseDataMessage(local_message_number, time_offset);
    }

    fn parseDefinitionMessage(self: *Parser, header: u8) !void {
        const local_message_number = header & 0x0f;
        _ = try self.readU8();
        const architecture = try self.readU8();
        const endian: std.builtin.Endian = if (architecture == 0) .little else .big;
        const global_message_number = try self.readU16(endian);
        const field_count = try self.readU8();

        var fields = std.ArrayList(FieldDef).init(self.allocator);
        errdefer fields.deinit();
        try fields.ensureTotalCapacity(field_count);

        var i: usize = 0;
        while (i < field_count) : (i += 1) {
            const number = try self.readU8();
            const size = try self.readU8();
            const raw_base_type = try self.readU8();
            const base_type: BaseType = @enumFromInt(@as(u5, @intCast(raw_base_type & 0x1f)));
            fields.appendAssumeCapacity(.{ .number = number, .size = size, .base_type = base_type });
        }

        var developer_fields = std.ArrayList(DeveloperFieldDef).init(self.allocator);
        errdefer developer_fields.deinit();
        if ((header & 0x20) != 0) {
            const developer_field_count = try self.readU8();
            try developer_fields.ensureTotalCapacity(developer_field_count);
            var developer_index: usize = 0;
            while (developer_index < developer_field_count) : (developer_index += 1) {
                const field_number = try self.readU8();
                const size = try self.readU8();
                const developer_data_index = try self.readU8();
                developer_fields.appendAssumeCapacity(.{
                    .field_number = field_number,
                    .size = size,
                    .developer_data_index = developer_data_index,
                });
            }
        }

        if (self.definitions[local_message_number]) |*existing| existing.deinit();
        self.definitions[local_message_number] = .{
            .global_message_number = global_message_number,
            .little_endian = architecture == 0,
            .fields = fields,
            .developer_fields = developer_fields,
        };
    }

    fn parseDataMessage(self: *Parser, local_message_number: u8, compressed_time_offset: ?u8) !void {
        const definition = self.definitions[local_message_number] orelse return error.MissingDefinitionMessage;
        const endian: std.builtin.Endian = if (definition.little_endian) .little else .big;
        const known_kind = kindName(definition.global_message_number);

        const record = c.rb_hash_new();
        var developer_description_builder = DeveloperDescriptionBuilder{};
        for (definition.fields.items) |field| {
            const bytes = try self.readBytes(field.size);
            const scalar = parseScalar(field.base_type, bytes, endian);
            if (definition.global_message_number == 206) developer_description_builder.capture(field.number, scalar);
            try self.addField(record, definition.global_message_number, field, scalar);
        }
        if (definition.global_message_number == 206) {
            if (developer_description_builder.key()) |key| {
                if (developer_description_builder.description()) |description| {
                    try self.developer_descriptions.put(key, description);
                }
            }
        }
        for (definition.developer_fields.items) |developer_field| {
            const bytes = try self.readBytes(developer_field.size);
            try self.addDeveloperField(record, developer_field, bytes, endian);
        }

        if (compressed_time_offset) |time_offset| {
            const timestamp = self.updateCompressedTimestamp(time_offset);
            addPair(record, "timestamp", rbInt(timestamp), "s");
        }

        if (known_kind) |kind| {
            self.addRecord(kind, record);
        } else {
            var kind_buffer: [32]u8 = undefined;
            const kind = try std.fmt.bufPrint(&kind_buffer, "unknown_{}", .{definition.global_message_number});
            self.addRecord(kind, record);
        }
    }

    fn addField(
        self: *Parser,
        record: VALUE,
        global_message_number: u16,
        field: FieldDef,
        scalar: Scalar,
    ) !void {
        if (global_message_number == 20) {
            try self.addRecordField(record, field, scalar);
            return;
        }

        if (fieldInfo(global_message_number, field.number)) |info| {
            addConvertedField(record, info, scalar);
        } else {
            var name_buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buffer, "unknown_{}", .{field.number}) catch return;
            addPair(record, name, rbValue(scalar), "");
        }
    }

    fn addDeveloperField(
        self: *Parser,
        record: VALUE,
        field: DeveloperFieldDef,
        bytes: []const u8,
        endian: std.builtin.Endian,
    ) !void {
        const description = self.developer_descriptions.get(
            developerDescriptionKey(field.developer_data_index, field.field_number),
        ) orelse return error.MissingDeveloperDefinitionMessage;
        const scalar = parseScalar(description.base_type, bytes, endian);
        addConvertedField(record, .{
            .name = description.name,
            .units = description.units,
            .scale = description.scale,
            .offset = description.offset,
        }, scalar);
    }

    fn addRecordField(self: *Parser, record: VALUE, field: FieldDef, scalar: Scalar) !void {
        switch (field.number) {
            2 => if (scalar.toU64()) |raw| addPair(record, "enhanced_altitude", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 5.0 - 500.0), "m"),
            6 => if (scalar.toU64()) |raw| addPair(record, "enhanced_speed", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 1000.0), "m/s"),
            8 => try self.addCompressedSpeedDistance(record, scalar),
            28 => try self.addCompressedAccumulatedPower(record, scalar),
            else => {
                if (recordFieldInfo(field.number)) |info| {
                    addConvertedField(record, info, scalar);
                    if (field.number == 253) {
                        if (scalar.toU64()) |raw| self.base_timestamp = @as(i64, @intCast(raw)) + FIT_EPOCH_OFFSET;
                    }
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_{}", .{field.number}) catch return;
                    addPair(record, name, rbValue(scalar), "");
                }
            },
        }
    }

    fn addCompressedSpeedDistance(self: *Parser, record: VALUE, scalar: Scalar) !void {
        const raw = scalar.toU64() orelse return;
        const speed = raw & 0x0fff;
        const distance = (raw >> 12) & 0x0fff;

        addPair(record, "enhanced_speed", rbFloat(@as(f64, @floatFromInt(speed)) / 100.0), "m/s");
        const accumulated = try self.accumulate(20, 5, distance);
        addPair(record, "distance", rbFloat(@as(f64, @floatFromInt(accumulated)) / 16.0), "m");
    }

    fn addCompressedAccumulatedPower(self: *Parser, record: VALUE, scalar: Scalar) !void {
        const raw = scalar.toU64() orelse return;
        const accumulated = try self.accumulate(20, 29, raw & 0xffff);
        addPair(record, "accumulated_power", rbInt(@intCast(accumulated)), "watts");
    }

    fn accumulate(self: *Parser, message_number: u16, field_number: u8, value: u64) !u64 {
        const key = (@as(u32, message_number) << 8) | field_number;
        const current = self.accumulators.get(key) orelse 0;
        const next = current + value;
        try self.accumulators.put(key, next);
        return next;
    }

    fn updateCompressedTimestamp(self: *Parser, offset: u8) i64 {
        const mask: i64 = 0x0000001f;
        var value = @as(i64, offset) + (self.base_timestamp & ~mask);
        if (@as(i64, offset) < (self.base_timestamp & mask)) value += mask + 1;
        self.base_timestamp = value;
        return value;
    }

    fn addRecord(self: *Parser, kind: []const u8, record: VALUE) void {
        const entry = c.rb_hash_new();
        _ = c.rb_hash_aset(entry, rbSym("kind"), rbSym(kind));
        _ = c.rb_hash_aset(entry, rbSym("fields"), record);
        _ = c.rb_ary_push(self.all_records, entry);

        if (knownKindIndex(kind)) |index| {
            if (self.groups[index] == Qnil) self.groups[index] = c.rb_ary_new();
            _ = c.rb_ary_push(self.groups[index], record);
        }
    }

    fn buildRecordsHash(self: *Parser) VALUE {
        const hash = c.rb_hash_new();
        for (known_kinds, 0..) |kind, index| {
            if (self.groups[index] != Qnil) {
                _ = c.rb_hash_aset(hash, rbSym(kind), self.groups[index]);
            }
        }
        return hash;
    }

    fn readU8(self: *Parser) !u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn readU16(self: *Parser, endian: std.builtin.Endian) !u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], endian);
    }

    fn readBytes(self: *Parser, len: usize) ![]const u8 {
        if (self.offset + len > self.end) return error.InvalidFitData;
        const bytes = self.data[self.offset .. self.offset + len];
        self.offset += len;
        return bytes;
    }
};

const known_kinds = [_][]const u8{
    "activity",
    "developer_data_id",
    "device_info",
    "event",
    "field_description",
    "file_id",
    "lap",
    "record",
    "session",
};

fn knownKindIndex(kind: []const u8) ?usize {
    for (known_kinds, 0..) |known, index| {
        if (std.mem.eql(u8, known, kind)) return index;
    }
    return null;
}

fn kindName(global_message_number: u16) ?[]const u8 {
    return switch (global_message_number) {
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

fn fieldInfo(message_number: u16, field_number: u8) ?FieldInfo {
    return switch (message_number) {
        0 => switch (field_number) {
            4 => .{ .name = "time_created", .units = "s", .date_time = true },
            253 => .{ .name = "timestamp", .units = "s", .date_time = true },
            else => null,
        },
        18, 19, 21, 23, 34 => switch (field_number) {
            253 => .{ .name = "timestamp", .units = "s", .date_time = true },
            else => null,
        },
        206 => switch (field_number) {
            0 => .{ .name = "developer_data_index" },
            1 => .{ .name = "field_definition_number" },
            2 => .{ .name = "fit_base_type_id", .fit_base_type = true },
            3 => .{ .name = "field_name" },
            4 => .{ .name = "array" },
            5 => .{ .name = "components" },
            6 => .{ .name = "scale" },
            7 => .{ .name = "offset" },
            8 => .{ .name = "units" },
            9 => .{ .name = "bits" },
            10 => .{ .name = "accumulate" },
            13 => .{ .name = "fit_base_unit_id" },
            14 => .{ .name = "native_mesg_num" },
            15 => .{ .name = "native_field_num" },
            253 => .{ .name = "timestamp", .units = "s", .date_time = true },
            else => null,
        },
        207 => switch (field_number) {
            0 => .{ .name = "developer_id" },
            1 => .{ .name = "application_id" },
            2 => .{ .name = "manufacturer_id" },
            3 => .{ .name = "developer_data_index" },
            4 => .{ .name = "application_version" },
            253 => .{ .name = "timestamp", .units = "s", .date_time = true },
            else => null,
        },
        else => null,
    };
}

fn recordFieldInfo(field_number: u8) ?FieldInfo {
    return switch (field_number) {
        0 => .{ .name = "position_lat", .units = "semicircles" },
        1 => .{ .name = "position_long", .units = "semicircles" },
        3 => .{ .name = "heart_rate", .units = "bpm" },
        4 => .{ .name = "cadence", .units = "rpm" },
        5 => .{ .name = "distance", .units = "m", .scale = 100.0 },
        7 => .{ .name = "power", .units = "watts" },
        29 => .{ .name = "accumulated_power", .units = "watts" },
        42 => .{ .name = "activity_type", .activity_type = true },
        73 => .{ .name = "enhanced_speed", .units = "m/s", .scale = 1000.0 },
        78 => .{ .name = "enhanced_altitude", .units = "m", .scale = 5.0, .offset = 500.0 },
        85 => .{ .name = "step_length", .units = "mm", .scale = 10.0 },
        253 => .{ .name = "timestamp", .units = "s", .date_time = true },
        else => null,
    };
}

fn parseScalar(base_type: BaseType, bytes: []const u8, endian: std.builtin.Endian) Scalar {
    const base_size = baseTypeSize(base_type);
    if (base_type == .string) return .{ .string = trimString(bytes) };
    if (bytes.len < base_size) return .none;
    const raw = bytes[0..base_size];

    if (isInvalid(base_type, raw, endian)) return .none;

    return switch (base_type) {
        .enum_type, .uint8, .uint8z, .byte => .{ .unsigned = raw[0] },
        .sint8 => .{ .signed = @as(i8, @bitCast(raw[0])) },
        .sint16 => .{ .signed = std.mem.readInt(i16, raw[0..2], endian) },
        .uint16, .uint16z => .{ .unsigned = std.mem.readInt(u16, raw[0..2], endian) },
        .sint32 => .{ .signed = std.mem.readInt(i32, raw[0..4], endian) },
        .uint32, .uint32z => .{ .unsigned = std.mem.readInt(u32, raw[0..4], endian) },
        .sint64 => .{ .signed = std.mem.readInt(i64, raw[0..8], endian) },
        .uint64, .uint64z => .{ .unsigned = std.mem.readInt(u64, raw[0..8], endian) },
        .float32 => .{ .float = @as(f64, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, raw[0..4], endian))))) },
        .float64 => .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, raw[0..8], endian))) },
        .string => unreachable,
    };
}

fn isInvalid(base_type: BaseType, raw: []const u8, endian: std.builtin.Endian) bool {
    return switch (base_type) {
        .enum_type, .uint8, .uint8z, .byte => raw[0] == 0xff,
        .sint8 => raw[0] == 0x7f,
        .sint16 => std.mem.readInt(u16, raw[0..2], endian) == 0x7fff,
        .uint16, .uint16z => std.mem.readInt(u16, raw[0..2], endian) == 0xffff,
        .sint32 => std.mem.readInt(u32, raw[0..4], endian) == 0x7fffffff,
        .uint32, .uint32z => std.mem.readInt(u32, raw[0..4], endian) == 0xffffffff,
        .sint64 => std.mem.readInt(u64, raw[0..8], endian) == 0x7fffffffffffffff,
        .uint64, .uint64z => std.mem.readInt(u64, raw[0..8], endian) == 0xffffffffffffffff,
        .float32, .float64, .string => false,
    };
}

fn baseTypeSize(base_type: BaseType) usize {
    return switch (base_type) {
        .enum_type, .sint8, .uint8, .uint8z, .byte => 1,
        .sint16, .uint16, .uint16z => 2,
        .sint32, .uint32, .uint32z, .float32 => 4,
        .sint64, .uint64, .uint64z, .float64 => 8,
        .string => 1,
    };
}

fn trimString(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

fn developerDescriptionKey(developer_data_index: u8, field_definition_number: u8) u16 {
    return (@as(u16, developer_data_index) << 8) | field_definition_number;
}

fn baseTypeFromFitBaseTypeId(value: u8) ?BaseType {
    return switch (value) {
        0 => .enum_type,
        1 => .sint8,
        2 => .uint8,
        7 => .string,
        10 => .uint8z,
        13 => .byte,
        131 => .sint16,
        132 => .uint16,
        133 => .sint32,
        134 => .uint32,
        136 => .float32,
        137 => .float64,
        139 => .uint16z,
        140 => .uint32z,
        142 => .sint64,
        143 => .uint64,
        144 => .uint64z,
        else => null,
    };
}

fn fitBaseTypeName(value: u8) []const u8 {
    return switch (value) {
        0 => "enum",
        1 => "sint8",
        2 => "uint8",
        7 => "string",
        10 => "uint8z",
        13 => "byte",
        131 => "sint16",
        132 => "uint16",
        133 => "sint32",
        134 => "uint32",
        136 => "float32",
        137 => "float64",
        139 => "uint16z",
        140 => "uint32z",
        142 => "sint64",
        143 => "uint64",
        144 => "uint64z",
        else => "unknown",
    };
}

fn addConvertedField(record: VALUE, info: FieldInfo, scalar: Scalar) void {
    if (info.activity_type) {
        const value = scalar.toU64() orelse return;
        addPair(record, info.name, rbString(activityTypeName(@intCast(value))), info.units);
        return;
    }

    if (info.fit_base_type) {
        const value = scalar.toU64() orelse return;
        addPair(record, info.name, rbString(fitBaseTypeName(@intCast(value))), info.units);
        return;
    }

    if (info.date_time) {
        const value = scalar.toU64() orelse return;
        addPair(record, info.name, rbInt(@as(i64, @intCast(value)) + FIT_EPOCH_OFFSET), info.units);
        return;
    }

    if (scalar.toF64()) |value| {
        if (info.scale != 1.0 or info.offset != 0.0) {
            addPair(record, info.name, rbFloat(value / info.scale - info.offset), info.units);
        } else {
            addPair(record, info.name, rbValue(scalar), info.units);
        }
        return;
    }

    if (info.scale == 1.0 and info.offset == 0.0) {
        addPair(record, info.name, rbValue(scalar), info.units);
    }
}

fn activityTypeName(value: u8) []const u8 {
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

fn rbValue(scalar: Scalar) VALUE {
    return switch (scalar) {
        .none => Qnil,
        .signed => |value| rbInt(value),
        .unsigned => |value| rbInt(@intCast(value)),
        .float => |value| rbFloat(value),
        .string => |value| rbString(value),
    };
}

fn addPair(record: VALUE, field_name: []const u8, value: VALUE, units: []const u8) void {
    if (value == Qnil) return;
    const pair = c.rb_hash_new();
    _ = c.rb_hash_aset(pair, rbSym("units"), rbString(units));
    _ = c.rb_hash_aset(pair, rbSym("value"), value);
    _ = c.rb_hash_aset(record, rbSym(field_name), pair);
}

fn rbSym(name: []const u8) VALUE {
    var buffer: [128]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buffer, "{s}", .{name}) catch unreachable;
    return c.rb_id2sym(c.rb_intern(z.ptr));
}

fn rbString(value: []const u8) VALUE {
    return c.rb_str_new(value.ptr, @intCast(value.len));
}

fn rbInt(value: i64) VALUE {
    return c.rb_ll2inum(value);
}

fn rbFloat(value: f64) VALUE {
    return c.rb_float_new(value);
}

fn raiseRuntime(message: []const u8) VALUE {
    var buffer: [256]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buffer, "{s}", .{message}) catch "fit_kit error";
    c.rb_raise(c.rb_eRuntimeError, z.ptr);
    return Qnil;
}

fn fit_parse_result_records_hash(self: VALUE) callconv(.c) VALUE {
    return c.rb_iv_get(self, "@records_hash");
}

fn fit_kit_parse_fit_file(_: VALUE, path_value: VALUE) callconv(.c) VALUE {
    var mutable_path = path_value;
    const path_ptr = c.rb_string_value_cstr(&mutable_path);
    const path = std.mem.span(path_ptr);

    const allocator = std.heap.c_allocator;
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024 * 128) catch |err| {
        return raiseRuntime(@errorName(err));
    };
    defer allocator.free(data);

    var parser = Parser.init(allocator, data) catch |err| {
        return raiseRuntime(@errorName(err));
    };
    defer parser.deinit();

    return parser.parse() catch |err| {
        return raiseRuntime(@errorName(err));
    };
}

export fn Init_fit_kit() void {
    const fit_kit_module = c.rb_define_module("FitKit");
    fit_parse_result_class = c.rb_define_class("FitParseResult", c.rb_cObject);

    c.rb_define_singleton_method(
        fit_kit_module,
        "parse_fit_file",
        @ptrCast(&fit_kit_parse_fit_file),
        1,
    );
    c.rb_define_method(
        fit_parse_result_class,
        "records_hash",
        @ptrCast(&fit_parse_result_records_hash),
        0,
    );
}
