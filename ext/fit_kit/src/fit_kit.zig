const std = @import("std");
const profile = @import("profile.zig");

const c = @cImport({
    @cInclude("ruby.h");
});

const VALUE = c.VALUE;
const Qnil: VALUE = c.RUBY_Qnil;
const FIT_EPOCH_OFFSET: i64 = 631065600;
const CRC_TABLE = [_]u16{
    0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401,
    0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400,
};

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

const NativeFieldData = struct {
    field: FieldDef,
    bytes: []const u8,
    scalar: Scalar,
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

const FieldInfo = profile.FieldInfo;

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
    data_start: usize = 0,
    crc: u16 = 0,
    definitions: [16]?Definition = [_]?Definition{null} ** 16,
    groups: [known_kinds.len]VALUE = [_]VALUE{Qnil} ** known_kinds.len,
    all_records: VALUE = Qnil,
    base_timestamp: i64 = 0,
    accumulators: std.AutoHashMap(u32, u64),
    hr_event_timestamp_accumulator: ?[10]u64 = null,
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

            try self.validateDataCrc();
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
        self.data_start = self.offset;
        self.end = self.offset + @as(usize, data_size);
        if (self.end + 2 > self.data.len) return error.InvalidFitData;

        self.crc = 0;
        if (header_size > 12) {
            const header_crc = std.mem.readInt(u16, self.data[header_start + 12 ..][0..2], .little);
            if (header_crc > 0) {
                const calculated = calculateCrc(self.data[header_start .. header_start + header_size - 2]);
                if (calculated != header_crc) return error.InvalidFitCrc;
                return;
            }
        }

        self.crc = updateCrc(0, self.data[header_start .. header_start + header_size]);
    }

    fn validateDataCrc(self: *Parser) !void {
        if (self.offset != self.end) return error.InvalidFitData;
        if (self.offset + 2 > self.data.len) return error.InvalidFitData;

        const expected = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
        const calculated = updateCrc(self.crc, self.data[self.data_start..self.end]);
        if (calculated != expected) return error.InvalidFitCrc;
    }

    fn resetFileState(self: *Parser) void {
        for (&self.definitions) |*definition| {
            if (definition.*) |*value| value.deinit();
            definition.* = null;
        }
        self.base_timestamp = 0;
        self.accumulators.clearRetainingCapacity();
        self.hr_event_timestamp_accumulator = null;
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
            var base_type: BaseType = @enumFromInt(@as(u5, @intCast(raw_base_type & 0x1f)));
            if (size % baseTypeSize(base_type) != 0) base_type = .byte;
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
        var file_id_manufacturer: ?u64 = null;
        var device_info_manufacturer: ?u64 = null;
        var device_info_source_type: ?u64 = null;
        var event_number: ?u64 = null;
        var workout_step_duration_type: ?u64 = null;
        var workout_step_target_type: ?u64 = null;
        var monitoring_activity_type: ?u64 = null;
        var lap_sport: ?u64 = null;
        var session_sport: ?u64 = null;
        var training_file_manufacturer: ?u64 = null;

        var native_fields = std.ArrayList(NativeFieldData).init(self.allocator);
        defer native_fields.deinit();
        try native_fields.ensureTotalCapacity(definition.fields.items.len);

        for (definition.fields.items) |field| {
            const bytes = try self.readBytes(field.size);
            const scalar = parseScalar(field.base_type, bytes, endian);
            if (definition.global_message_number == 206) developer_description_builder.capture(field.number, scalar);
            if (definition.global_message_number == 0 and field.number == 1) file_id_manufacturer = scalar.toU64();
            if (definition.global_message_number == 23 and field.number == 2) device_info_manufacturer = scalar.toU64();
            if (definition.global_message_number == 23 and field.number == 25) device_info_source_type = scalar.toU64();
            if (definition.global_message_number == 21 and field.number == 0) event_number = scalar.toU64();
            if (definition.global_message_number == 27 and field.number == 1) workout_step_duration_type = scalar.toU64();
            if (definition.global_message_number == 27 and field.number == 3) workout_step_target_type = scalar.toU64();
            if (definition.global_message_number == 55 and field.number == 5) monitoring_activity_type = scalar.toU64();
            if (definition.global_message_number == 19 and field.number == 25) lap_sport = scalar.toU64();
            if (definition.global_message_number == 18 and field.number == 5) session_sport = scalar.toU64();
            if (definition.global_message_number == 72 and field.number == 1) training_file_manufacturer = scalar.toU64();
            native_fields.appendAssumeCapacity(.{ .field = field, .bytes = bytes, .scalar = scalar });
        }

        for (native_fields.items) |native_field| {
            try self.addField(
                record,
                definition.global_message_number,
                native_field.field,
                native_field.bytes,
                endian,
                file_id_manufacturer,
                device_info_manufacturer,
                device_info_source_type,
                event_number,
                workout_step_duration_type,
                workout_step_target_type,
                monitoring_activity_type,
                lap_sport,
                session_sport,
                training_file_manufacturer,
            );
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
            const kind = try std.fmt.bufPrint(&kind_buffer, "{}", .{definition.global_message_number});
            self.addRecord(kind, record);
        }
    }

    fn addField(
        self: *Parser,
        record: VALUE,
        global_message_number: u16,
        field: FieldDef,
        bytes: []const u8,
        endian: std.builtin.Endian,
        file_id_manufacturer: ?u64,
        device_info_manufacturer: ?u64,
        device_info_source_type: ?u64,
        event_number: ?u64,
        workout_step_duration_type: ?u64,
        workout_step_target_type: ?u64,
        monitoring_activity_type: ?u64,
        lap_sport: ?u64,
        session_sport: ?u64,
        training_file_manufacturer: ?u64,
    ) !void {
        const scalar = parseScalar(field.base_type, bytes, endian);
        if (global_message_number == 0) {
            self.addFileIdField(record, field, scalar, bytes, endian, file_id_manufacturer);
            return;
        }

        if (global_message_number == 23) {
            self.addDeviceInfoField(record, field, scalar, bytes, endian, device_info_manufacturer, device_info_source_type);
            return;
        }

        if (global_message_number == 34) {
            self.addActivityField(record, field, scalar, bytes, endian);
            return;
        }

        if (global_message_number == 21) {
            self.addEventField(record, field, scalar, bytes, endian, event_number);
            return;
        }

        if (global_message_number == 18) {
            self.addSessionField(record, field, scalar, bytes, endian, session_sport);
            return;
        }

        if (global_message_number == 19) {
            self.addLapField(record, field, scalar, bytes, endian, lap_sport);
            return;
        }

        if (global_message_number == 20) {
            try self.addRecordField(record, field, scalar, bytes, endian);
            return;
        }

        if (global_message_number == 27) {
            self.addWorkoutStepField(record, field, scalar, bytes, endian, workout_step_duration_type, workout_step_target_type);
            return;
        }

        if (global_message_number == 26) {
            self.addWorkoutField(record, field, scalar, bytes, endian);
            return;
        }

        if (global_message_number == 30) {
            self.addWeightScaleField(record, field, scalar, bytes, endian);
            return;
        }

        if (global_message_number == 55) {
            self.addMonitoringField(record, field, scalar, bytes, endian, monitoring_activity_type);
            return;
        }

        if (global_message_number == 132) {
            try self.addHrField(record, field, scalar, bytes, endian);
            return;
        }

        if (global_message_number == 72) {
            self.addTrainingFileField(record, field, scalar, bytes, endian, training_file_manufacturer);
            return;
        }

        if (fieldInfo(global_message_number, field.number)) |info| {
            addConvertedBytes(record, info, field.base_type, bytes, endian);
        } else {
            if (skipUnknownField(global_message_number, field.number, scalar)) return;
            var name_buffer: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
            addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
        }
    }

    fn addFileIdField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        file_id_manufacturer: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            0 => {
                const value = scalar.toU64() orelse return;
                addPair(record, "type", rbString(fileTypeName(@intCast(value))), "");
            },
            1 => {
                const value = scalar.toU64() orelse return;
                addManufacturerPair(record, value);
            },
            2 => {
                const name = if (isGarminProductManufacturer(file_id_manufacturer)) "garmin_product" else "product";
                if (std.mem.eql(u8, name, "garmin_product")) {
                    if (scalar.toU64()) |value| {
                        if (profile.garminProductName(value)) |product| {
                            addPair(record, name, rbString(product), "");
                            return;
                        }
                    }
                }
                addConvertedBytes(record, .{ .name = name }, field.base_type, bytes, endian);
            },
            else => {
                if (fieldInfo(0, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addDeviceInfoField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        device_info_manufacturer: ?u64,
        device_info_source_type: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            1 => {
                const source_type = device_info_source_type orelse std.math.maxInt(u64);
                if (source_type == 5) {
                    const value = scalar.toU64() orelse return;
                    if (localDeviceTypeName(value)) |name| {
                        addPair(record, "local_device_type", rbString(name), "");
                    } else {
                        addPair(record, "local_device_type", rbInt(@intCast(value)), "");
                    }
                } else if (source_type == 3) {
                    addPair(record, "ble_device_type", rbValue(scalar), "");
                } else if (source_type == 1) {
                    const value = scalar.toU64() orelse return;
                    if (antplusDeviceTypeName(value)) |name| {
                        addPair(record, "antplus_device_type", rbString(name), "");
                    } else {
                        addPair(record, "antplus_device_type", rbInt(@intCast(value)), "");
                    }
                } else if (source_type == 0) {
                    addPair(record, "ant_device_type", rbValue(scalar), "");
                } else {
                    addPair(record, "device_type", rbValue(scalar), "");
                }
            },
            2 => {
                const value = scalar.toU64() orelse return;
                addManufacturerPair(record, value);
            },
            3 => {
                if ((device_info_source_type orelse std.math.maxInt(u64)) == 5 and (scalar.toU64() orelse 0) == 0) return;
                if (fieldInfo(23, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                }
            },
            4 => {
                const name = if (isGarminProductManufacturer(device_info_manufacturer)) "garmin_product" else "product";
                if (std.mem.eql(u8, name, "garmin_product")) {
                    if (scalar.toU64()) |value| {
                        if (profile.garminProductName(value)) |product| {
                            addPair(record, name, rbString(product), "");
                            return;
                        }
                    }
                }
                addConvertedBytes(record, .{ .name = name }, field.base_type, bytes, endian);
            },
            20, 21 => {
                if ((device_info_source_type orelse std.math.maxInt(u64)) == 5) return;
                if (fieldInfo(23, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                }
            },
            24 => {
                if ((device_info_source_type orelse std.math.maxInt(u64)) == 5) return;
                var name_buffer: [32]u8 = undefined;
                const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
            },
            25 => {
                const value = scalar.toU64() orelse return;
                if (sourceTypeName(value)) |name| {
                    addPair(record, "source_type", rbString(name), "");
                } else {
                    addPair(record, "source_type", rbInt(@intCast(value)), "");
                }
            },
            else => {
                if (fieldInfo(23, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addWorkoutStepField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        duration_type: ?u64,
        target_type: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            1 => {
                const value = scalar.toU64() orelse return;
                if (wktStepDurationName(value)) |name| {
                    addPair(record, "duration_type", rbString(name), "");
                } else {
                    addPair(record, "duration_type", rbInt(@intCast(value)), "");
                }
            },
            2 => {
                const value = scalar.toF64() orelse return;
                switch (duration_type orelse std.math.maxInt(u64)) {
                    0, 28 => addPair(record, "duration_time", rbFloat(value / 1000.0), "s"),
                    1 => addPair(record, "duration_distance", rbFloat(value / 100.0), "m"),
                    2, 3 => addPair(record, "duration_hr", rbValue(scalar), "% or bpm"),
                    4 => addPair(record, "duration_calories", rbValue(scalar), "calories"),
                    6, 7, 8, 9, 10, 11, 12, 13 => addPair(record, "duration_step", rbValue(scalar), ""),
                    14, 15 => addPair(record, "duration_power", rbValue(scalar), "% or watts"),
                    29 => addPair(record, "duration_reps", rbValue(scalar), ""),
                    else => addPair(record, "duration_value", rbValue(scalar), ""),
                }
            },
            3 => {
                const value = scalar.toU64() orelse return;
                if (wktStepTargetName(value)) |name| {
                    addPair(record, "target_type", rbString(name), "");
                } else {
                    addPair(record, "target_type", rbInt(@intCast(value)), "");
                }
            },
            4 => {
                switch (target_type orelse std.math.maxInt(u64)) {
                    0 => addPair(record, "target_speed_zone", rbValue(scalar), ""),
                    1 => addPair(record, "target_hr_zone", rbValue(scalar), ""),
                    3 => addPair(record, "target_cadence_zone", rbValue(scalar), ""),
                    4 => addPair(record, "target_power_zone", rbValue(scalar), ""),
                    11 => addPair(record, "target_stroke_type", rbValue(scalar), ""),
                    else => switch (duration_type orelse std.math.maxInt(u64)) {
                        6 => addPair(record, "repeat_steps", rbValue(scalar), ""),
                        7 => {
                            const value = scalar.toF64() orelse return;
                            addPair(record, "repeat_time", rbFloat(value / 1000.0), "s");
                        },
                        8 => {
                            const value = scalar.toF64() orelse return;
                            addPair(record, "repeat_distance", rbFloat(value / 100.0), "m");
                        },
                        9 => addPair(record, "repeat_calories", rbValue(scalar), "calories"),
                        10, 11 => addPair(record, "repeat_hr", rbValue(scalar), "% or bpm"),
                        12, 13 => addPair(record, "repeat_power", rbValue(scalar), "% or watts"),
                        else => addPair(record, "target_value", rbValue(scalar), ""),
                    },
                }
            },
            5 => switch (target_type orelse std.math.maxInt(u64)) {
                0 => addScaledPair(record, "custom_target_speed_low", scalar, 1000.0, 0.0, "m/s"),
                1 => addPair(record, "custom_target_heart_rate_low", rbValue(scalar), "% or bpm"),
                3 => addPair(record, "custom_target_cadence_low", rbValue(scalar), "rpm"),
                4 => addPair(record, "custom_target_power_low", rbValue(scalar), "% or watts"),
                else => addPair(record, "custom_target_value_low", rbValue(scalar), ""),
            },
            6 => switch (target_type orelse std.math.maxInt(u64)) {
                0 => addScaledPair(record, "custom_target_speed_high", scalar, 1000.0, 0.0, "m/s"),
                1 => addPair(record, "custom_target_heart_rate_high", rbValue(scalar), "% or bpm"),
                3 => addPair(record, "custom_target_cadence_high", rbValue(scalar), "rpm"),
                4 => addPair(record, "custom_target_power_high", rbValue(scalar), "% or watts"),
                else => addPair(record, "custom_target_value_high", rbValue(scalar), ""),
            },
            7 => {
                const value = scalar.toU64() orelse return;
                if (intensityName(value)) |name| {
                    addPair(record, "intensity", rbString(name), "");
                } else {
                    addPair(record, "intensity", rbInt(@intCast(value)), "");
                }
            },
            else => {
                if (fieldInfo(27, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addWorkoutField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
    ) void {
        _ = self;
        switch (field.number) {
            5 => {
                const value = scalar.toU64() orelse return;
                if (workoutCapabilitiesName(value)) |name| {
                    addPair(record, "capabilities", rbString(name), "");
                } else {
                    addPair(record, "capabilities", rbInt(@intCast(value)), "");
                }
            },
            else => {
                if (fieldInfo(26, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addWeightScaleField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
    ) void {
        _ = self;
        switch (field.number) {
            0 => {
                const value = scalar.toU64() orelse return;
                if (value == 65534) {
                    addPair(record, "weight", rbString("calculating"), "kg");
                } else {
                    addPair(record, "weight", rbInt(@intCast(value)), "kg");
                }
            },
            else => {
                if (fieldInfo(30, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addMonitoringField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        activity_type: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            3 => {
                switch (activity_type orelse std.math.maxInt(u64)) {
                    1, 6 => addPair(record, "steps", rbValue(scalar), "steps"),
                    2, 5 => addScaledPair(record, "strokes", scalar, 2.0, 0.0, "strokes"),
                    else => addScaledPair(record, "cycles", scalar, 2.0, 0.0, "cycles"),
                }
            },
            24 => {
                const raw = scalar.toU64() orelse return;
                const decoded_activity_type = raw & 0x1f;
                const intensity = (raw >> 5) & 0x07;
                addPair(record, "activity_type", rbString(activityTypeName(@intCast(decoded_activity_type))), "");
                addPair(record, "intensity", rbInt(@intCast(intensity)), "");
            },
            else => {
                if (fieldInfo(55, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addHrField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
    ) !void {
        switch (field.number) {
            1 => {
                const raw = scalar.toU64() orelse return;
                addPair(record, "fractional_timestamp", rbFloat(@as(f64, @floatFromInt(raw & 0xff)) / 256.0), "s");
            },
            10 => {
                const array = c.rb_ary_new_capa(10);
                var values: [10]u64 = undefined;
                var bit_offset: usize = 0;
                var index: usize = 0;
                while (index < 10) : (index += 1) {
                    values[index] = readBitsLe(bytes, bit_offset, 12);
                    bit_offset += 12;
                }
                self.accumulateHrEventTimestamps(&values);
                index = 0;
                while (index < values.len) : (index += 1) {
                    _ = c.rb_ary_push(array, rbFloat(@as(f64, @floatFromInt(values[index])) / 1024.0));
                }
                addPair(record, "event_timestamp", array, "s");
            },
            else => {
                if (fieldInfo(132, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addTrainingFileField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        training_file_manufacturer: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            0 => {
                const value = scalar.toU64() orelse return;
                addPair(record, "type", rbString(fileTypeName(@intCast(value))), "");
            },
            1 => {
                const value = scalar.toU64() orelse return;
                addManufacturerPair(record, value);
            },
            2 => {
                const name = if (isGarminProductManufacturer(training_file_manufacturer)) "garmin_product" else "product";
                if (std.mem.eql(u8, name, "garmin_product")) {
                    if (scalar.toU64()) |value| {
                        if (profile.garminProductName(value)) |product| {
                            addPair(record, name, rbString(product), "");
                            return;
                        }
                    }
                }
                addConvertedBytes(record, .{ .name = name }, field.base_type, bytes, endian);
            },
            else => {
                if (fieldInfo(72, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addActivityField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
    ) void {
        _ = self;
        switch (field.number) {
            2 => {
                const value = scalar.toU64() orelse return;
                if (profile.activityName(value)) |name| {
                    addPair(record, "type", rbString(name), "");
                } else {
                    addPair(record, "type", rbInt(@intCast(value)), "");
                }
            },
            else => {
                if (fieldInfo(34, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addEventField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        event_number: ?u64,
    ) void {
        switch (field.number) {
            0 => {
                const value = scalar.toU64() orelse return;
                if (profile.eventName(value)) |name| {
                    addPair(record, "event", rbString(name), "");
                } else {
                    addPair(record, "event", rbInt(@intCast(value)), "");
                }
            },
            1 => {
                const value = scalar.toU64() orelse return;
                if (profile.eventTypeName(value)) |name| {
                    addPair(record, "event_type", rbString(name), "");
                } else {
                    addPair(record, "event_type", rbInt(@intCast(value)), "");
                }
            },
            2 => if (scalar.toU64()) |raw| {
                self.addEventDataField(record, raw & 0xffff, event_number);
            },
            3 => if (scalar.toU64()) |raw| {
                self.addEventDataField(record, raw, event_number);
            },
            else => {
                if (fieldInfo(21, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addEventDataField(self: *Parser, record: VALUE, value: u64, event_number: ?u64) void {
        _ = self;
        switch (event_number orelse std.math.maxInt(u64)) {
            0 => {
                if (profile.timerTriggerName(value)) |name| {
                    addPair(record, "timer_trigger", rbString(name), "");
                } else {
                    addPair(record, "timer_trigger", rbInt(@intCast(value)), "");
                }
            },
            10 => addPair(record, "course_point_index", rbInt(@intCast(value)), ""),
            11 => addPair(record, "battery_level", rbFloat(@as(f64, @floatFromInt(value)) / 1000.0), "V"),
            12 => addPair(record, "virtual_partner_speed", rbFloat(@as(f64, @floatFromInt(value)) / 1000.0), "m/s"),
            13 => addPair(record, "hr_high_alert", rbInt(@intCast(value)), "bpm"),
            14 => addPair(record, "hr_low_alert", rbInt(@intCast(value)), "bpm"),
            15 => addPair(record, "speed_high_alert", rbFloat(@as(f64, @floatFromInt(value)) / 1000.0), "m/s"),
            16 => addPair(record, "speed_low_alert", rbFloat(@as(f64, @floatFromInt(value)) / 1000.0), "m/s"),
            17 => addPair(record, "cad_high_alert", rbInt(@intCast(value)), "rpm"),
            18 => addPair(record, "cad_low_alert", rbInt(@intCast(value)), "rpm"),
            19 => addPair(record, "power_high_alert", rbInt(@intCast(value)), "watts"),
            20 => addPair(record, "power_low_alert", rbInt(@intCast(value)), "watts"),
            23 => addPair(record, "time_duration_alert", rbFloat(@as(f64, @floatFromInt(value)) / 1000.0), "s"),
            24 => addPair(record, "distance_duration_alert", rbFloat(@as(f64, @floatFromInt(value)) / 100.0), "m"),
            25 => addPair(record, "calorie_duration_alert", rbInt(@intCast(value)), "calories"),
            27 => addPair(record, "fitness_equipment_state", rbInt(@intCast(value)), ""),
            33 => addPair(record, "sport_point", rbInt(@intCast(value)), ""),
            42, 43 => addPair(record, "gear_change_data", rbInt(@intCast(value)), ""),
            44 => addPair(record, "rider_position", rbInt(@intCast(value)), ""),
            47 => addPair(record, "comm_timeout", rbInt(@intCast(value)), ""),
            56 => addPair(record, "dive_alert", rbInt(@intCast(value)), ""),
            57 => addPair(record, "auto_activity_detect_duration", rbInt(@intCast(value)), "min"),
            75 => addPair(record, "radar_threat_alert", rbInt(@intCast(value)), ""),
            else => addPair(record, "data", rbInt(@intCast(value)), ""),
        }
    }

    fn addLapField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        lap_sport: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            0 => {
                const value = scalar.toU64() orelse return;
                if (profile.eventName(value)) |name| {
                    addPair(record, "event", rbString(name), "");
                } else {
                    addPair(record, "event", rbInt(@intCast(value)), "");
                }
            },
            1 => {
                const value = scalar.toU64() orelse return;
                if (profile.eventTypeName(value)) |name| {
                    addPair(record, "event_type", rbString(name), "");
                } else {
                    addPair(record, "event_type", rbInt(@intCast(value)), "");
                }
            },
            10 => switch (lap_sport orelse std.math.maxInt(u64)) {
                1, 11 => addPair(record, "total_strides", rbValue(scalar), "strides"),
                2, 5, 15, 37 => addPair(record, "total_strokes", rbValue(scalar), "strokes"),
                else => addPair(record, "total_cycles", rbValue(scalar), "cycles"),
            },
            13 => if (scalar.toU64()) |raw| {
                addPair(record, "enhanced_avg_speed", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 1000.0), "m/s");
            },
            14 => if (scalar.toU64()) |raw| {
                addPair(record, "enhanced_max_speed", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 1000.0), "m/s");
            },
            17 => {
                if ((lap_sport orelse std.math.maxInt(u64)) == 1) {
                    addPair(record, "avg_running_cadence", rbValue(scalar), "strides/min");
                } else {
                    addPair(record, "avg_cadence", rbValue(scalar), "rpm");
                }
            },
            18 => {
                if ((lap_sport orelse std.math.maxInt(u64)) == 1) {
                    addPair(record, "max_running_cadence", rbValue(scalar), "strides/min");
                } else {
                    addPair(record, "max_cadence", rbValue(scalar), "rpm");
                }
            },
            24 => {
                const value = scalar.toU64() orelse return;
                if (profile.lapTriggerName(value)) |name| {
                    addPair(record, "lap_trigger", rbString(name), "");
                } else {
                    addPair(record, "lap_trigger", rbInt(@intCast(value)), "");
                }
            },
            else => {
                if (fieldInfo(19, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
        }
    }

    fn addSessionField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
        session_sport: ?u64,
    ) void {
        _ = self;
        switch (field.number) {
            0 => {
                const value = scalar.toU64() orelse return;
                if (profile.eventName(value)) |name| {
                    addPair(record, "event", rbString(name), "");
                } else {
                    addPair(record, "event", rbInt(@intCast(value)), "");
                }
            },
            1 => {
                const value = scalar.toU64() orelse return;
                if (profile.eventTypeName(value)) |name| {
                    addPair(record, "event_type", rbString(name), "");
                } else {
                    addPair(record, "event_type", rbInt(@intCast(value)), "");
                }
            },
            10 => switch (session_sport orelse std.math.maxInt(u64)) {
                1, 11 => addPair(record, "total_strides", rbValue(scalar), "strides"),
                2, 5, 15, 37 => addPair(record, "total_strokes", rbValue(scalar), "strokes"),
                else => addPair(record, "total_cycles", rbValue(scalar), "cycles"),
            },
            14 => if (scalar.toU64()) |raw| {
                addPair(record, "enhanced_avg_speed", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 1000.0), "m/s");
            },
            15 => if (scalar.toU64()) |raw| {
                addPair(record, "enhanced_max_speed", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 1000.0), "m/s");
            },
            18 => {
                if ((session_sport orelse std.math.maxInt(u64)) == 1) {
                    addPair(record, "avg_running_cadence", rbValue(scalar), "strides/min");
                } else {
                    addPair(record, "avg_cadence", rbValue(scalar), "rpm");
                }
            },
            19 => {
                if ((session_sport orelse std.math.maxInt(u64)) == 1) {
                    addPair(record, "max_running_cadence", rbValue(scalar), "strides/min");
                } else {
                    addPair(record, "max_cadence", rbValue(scalar), "rpm");
                }
            },
            28 => {
                const value = scalar.toU64() orelse return;
                if (profile.sessionTriggerName(value)) |name| {
                    addPair(record, "trigger", rbString(name), "");
                } else {
                    addPair(record, "trigger", rbInt(@intCast(value)), "");
                }
            },
            else => {
                if (fieldInfo(18, field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
                }
            },
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
        addConvertedBytes(record, .{
            .name = description.name,
            .units = description.units,
            .scale = description.scale,
            .offset = description.offset,
        }, description.base_type, bytes, endian);
    }

    fn addRecordField(
        self: *Parser,
        record: VALUE,
        field: FieldDef,
        scalar: Scalar,
        bytes: []const u8,
        endian: std.builtin.Endian,
    ) !void {
        switch (field.number) {
            2 => if (scalar.toU64()) |raw| addPair(record, "enhanced_altitude", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 5.0 - 500.0), "m"),
            6 => if (scalar.toU64()) |raw| addPair(record, "enhanced_speed", rbFloat(@as(f64, @floatFromInt(raw & 0xffff)) / 1000.0), "m/s"),
            8 => try self.addCompressedSpeedDistance(record, scalar),
            28 => try self.addCompressedAccumulatedPower(record, scalar),
            else => {
                if (recordFieldInfo(field.number)) |info| {
                    addConvertedBytes(record, info, field.base_type, bytes, endian);
                    if (field.number == 253) {
                        if (scalar.toU64()) |raw| self.base_timestamp = @as(i64, @intCast(raw)) + FIT_EPOCH_OFFSET;
                    }
                } else {
                    var name_buffer: [32]u8 = undefined;
                    const name = std.fmt.bufPrintZ(&name_buffer, "unknown_field_{}", .{field.number}) catch return;
                    addPair(record, name, rbRawValue(field.base_type, bytes, endian), "");
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

    fn accumulateHrEventTimestamps(self: *Parser, values: *[10]u64) void {
        if (self.hr_event_timestamp_accumulator) |stored| {
            var next: [10]u64 = undefined;
            var index: usize = 0;
            while (index < values.len) : (index += 1) {
                next[index] = stored[index] + values[index];
                values[index] = next[index];
            }
            self.hr_event_timestamp_accumulator = next;
        } else {
            self.hr_event_timestamp_accumulator = values.*;
        }
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
        for (public_known_kind_order) |kind| {
            if (knownKindIndex(kind)) |index| {
                if (self.groups[index] != Qnil) {
                    _ = c.rb_hash_aset(hash, rbSym(kind), self.groups[index]);
                }
            }
        }
        for (known_kinds, 0..) |kind, index| {
            if (isPublicKnownKind(kind)) continue;
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

const known_kinds = profile.known_kinds;

const public_known_kind_order = [_][]const u8{
    "activity",
    "developer_data_id",
    "device_info",
    "event",
    "field_description",
    "file_id",
    "hrv",
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

fn isPublicKnownKind(kind: []const u8) bool {
    for (public_known_kind_order) |known| {
        if (std.mem.eql(u8, known, kind)) return true;
    }
    return false;
}

fn kindName(global_message_number: u16) ?[]const u8 {
    return profile.kindName(global_message_number);
}

fn fieldInfo(message_number: u16, field_number: u8) ?FieldInfo {
    return profile.fieldInfo(message_number, field_number);
}

fn skipUnknownField(global_message_number: u16, field_number: u8, scalar: Scalar) bool {
    if (global_message_number != 147) return false;
    return switch (field_number) {
        17, 18, 19, 20, 40 => true,
        44, 73 => (scalar.toU64() orelse 0) == 0,
        else => false,
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
        else => profile.fieldInfo(20, field_number),
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
        .float32 => {
            const value: f64 = @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, raw[0..4], endian))));
            return if (std.math.isFinite(value)) .{ .float = value } else .none;
        },
        .float64 => {
            const value: f64 = @bitCast(std.mem.readInt(u64, raw[0..8], endian));
            return if (std.math.isFinite(value)) .{ .float = value } else .none;
        },
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
        .float32 => !std.math.isFinite(@as(f64, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, raw[0..4], endian)))))),
        .float64 => !std.math.isFinite(@as(f64, @bitCast(std.mem.readInt(u64, raw[0..8], endian)))),
        .string => false,
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

fn calculateCrc(data: []const u8) u16 {
    return updateCrc(0, data);
}

fn updateCrc(initial: u16, data: []const u8) u16 {
    var crc = initial;
    for (data) |byte| crc = getCrc(crc, byte);
    return crc;
}

fn getCrc(initial: u16, byte: u8) u16 {
    var tmp = CRC_TABLE[initial & 0x0f];
    var crc = (initial >> 4) & 0x0fff;
    crc = crc ^ tmp ^ CRC_TABLE[byte & 0x0f];

    tmp = CRC_TABLE[crc & 0x0f];
    crc = (crc >> 4) & 0x0fff;
    crc = crc ^ tmp ^ CRC_TABLE[(byte >> 4) & 0x0f];

    return crc;
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
    addPair(record, info.name, rbConvertedScalar(info, scalar), info.units);
}

fn addConvertedBytes(
    record: VALUE,
    info: FieldInfo,
    base_type: BaseType,
    bytes: []const u8,
    endian: std.builtin.Endian,
) void {
    addPair(record, info.name, rbConvertedValue(info, base_type, bytes, endian), info.units);
}

fn rbConvertedValue(info: FieldInfo, base_type: BaseType, bytes: []const u8, endian: std.builtin.Endian) VALUE {
    if (base_type == .string) return rbConvertedScalar(info, parseScalar(base_type, bytes, endian));

    const base_size = baseTypeSize(base_type);
    if (bytes.len <= base_size) return rbConvertedScalar(info, parseScalar(base_type, bytes, endian));

    const count = bytes.len / base_size;
    const array = c.rb_ary_new_capa(@intCast(count));
    var has_valid = false;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const raw = bytes[index * base_size ..][0..base_size];
        const value = rbScaledElement(info, base_type, raw, endian);
        if (isValidArrayElement(base_type, raw, endian)) has_valid = true;
        _ = c.rb_ary_push(array, value);
    }

    return if (has_valid) array else Qnil;
}

fn rbScaledElement(info: FieldInfo, base_type: BaseType, raw: []const u8, endian: std.builtin.Endian) VALUE {
    const scalar = if (base_type == .byte) parseByteScalar(raw) else parseScalar(base_type, raw, endian);
    return rbScaledScalar(info, scalar);
}

fn rbConvertedScalar(info: FieldInfo, scalar: Scalar) VALUE {
    if (std.mem.eql(u8, info.name, "device_index")) {
        const value = scalar.toU64() orelse return Qnil;
        if (value == 0) return rbString("creator");
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "ant_network")) {
        const value = scalar.toU64() orelse return Qnil;
        if (antNetworkName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "auto_activity_detect")) {
        const value = scalar.toU64() orelse return Qnil;
        if (autoActivityDetectName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "backlight_mode")) {
        const value = scalar.toU64() orelse return Qnil;
        if (backlightModeName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "mounting_side")) {
        const value = scalar.toU64() orelse return Qnil;
        if (sideName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "battery_status")) {
        const value = scalar.toU64() orelse return Qnil;
        if (batteryStatusName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "time_mode")) {
        const value = scalar.toU64() orelse return Qnil;
        if (timeModeName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "date_mode")) {
        const value = scalar.toU64() orelse return Qnil;
        if (dateModeName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "activity_class")) {
        const value = scalar.toU64() orelse return Qnil;
        if (activityClassName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "dist_setting") or
        std.mem.eql(u8, info.name, "elev_setting") or
        std.mem.eql(u8, info.name, "height_setting") or
        std.mem.eql(u8, info.name, "speed_setting") or
        std.mem.eql(u8, info.name, "temperature_setting") or
        std.mem.eql(u8, info.name, "weight_setting"))
    {
        const value = scalar.toU64() orelse return Qnil;
        if (displayMeasureName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "power_setting")) {
        const value = scalar.toU64() orelse return Qnil;
        if (displayPowerName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "weight_display_unit")) {
        const value = scalar.toU64() orelse return Qnil;
        if (fitBaseUnitName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "hr_calc_type")) {
        const value = scalar.toU64() orelse return Qnil;
        if (hrZoneCalcName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "pwr_calc_type")) {
        const value = scalar.toU64() orelse return Qnil;
        if (pwrZoneCalcName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "reference_mesg")) {
        const value = scalar.toU64() orelse return Qnil;
        if (kindName(@intCast(value))) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "hr_setting")) {
        const value = scalar.toU64() orelse return Qnil;
        if (displayHeartName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (std.mem.eql(u8, info.name, "position_setting")) {
        const value = scalar.toU64() orelse return Qnil;
        if (displayPositionName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.activity_type) {
        const value = scalar.toU64() orelse return Qnil;
        return rbString(activityTypeName(@intCast(value)));
    }

    if (info.fit_base_type) {
        const value = scalar.toU64() orelse return Qnil;
        return rbString(fitBaseTypeName(@intCast(value)));
    }

    if (info.local_date_time) {
        const value = scalar.toU64() orelse return Qnil;
        return rbLocalDateTime(value);
    }

    if (info.gender) {
        const value = scalar.toU64() orelse return Qnil;
        if (profile.genderName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.sport) {
        const value = scalar.toU64() orelse return Qnil;
        if (profile.sportName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.language) {
        const value = scalar.toU64() orelse return Qnil;
        if (profile.languageName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.sub_sport) {
        const value = scalar.toU64() orelse return Qnil;
        if (profile.subSportName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.event) {
        const value = scalar.toU64() orelse return Qnil;
        if (profile.eventName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.event_type) {
        const value = scalar.toU64() orelse return Qnil;
        if (profile.eventTypeName(value)) |name| return rbString(name);
        return rbInt(@intCast(value));
    }

    if (info.date_time) {
        const value = scalar.toU64() orelse return Qnil;
        return rbInt(@as(i64, @intCast(value)) + FIT_EPOCH_OFFSET);
    }

    if (scalar.toF64()) |value| {
        if (info.scale != 1.0 or info.offset != 0.0) {
            return rbFloat(value / info.scale - info.offset);
        } else {
            return rbValue(scalar);
        }
    }

    if (info.scale == 1.0 and info.offset == 0.0) {
        return rbValue(scalar);
    }

    return Qnil;
}

fn rbScaledScalar(info: FieldInfo, scalar: Scalar) VALUE {
    if (scalar.toF64()) |value| {
        if (info.scale != 1.0 or info.offset != 0.0) {
            return rbFloat(value / info.scale - info.offset);
        }
    }

    return rbValue(scalar);
}

fn rbRawValue(base_type: BaseType, bytes: []const u8, endian: std.builtin.Endian) VALUE {
    if (base_type == .string) return rbValue(parseScalar(base_type, bytes, endian));

    const base_size = baseTypeSize(base_type);
    if (bytes.len <= base_size) return rbValue(parseScalar(base_type, bytes, endian));

    const count = bytes.len / base_size;
    const array = c.rb_ary_new_capa(@intCast(count));
    var has_valid = false;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const raw = bytes[index * base_size ..][0..base_size];
        const scalar = if (base_type == .byte) parseByteScalar(raw) else parseScalar(base_type, raw, endian);
        const value = rbValue(scalar);
        if (isValidArrayElement(base_type, raw, endian)) has_valid = true;
        _ = c.rb_ary_push(array, value);
    }

    return if (has_valid) array else Qnil;
}

fn parseByteScalar(raw: []const u8) Scalar {
    if (raw.len == 0) return .none;
    return .{ .unsigned = raw[0] };
}

fn isValidArrayElement(base_type: BaseType, raw: []const u8, endian: std.builtin.Endian) bool {
    return switch (base_type) {
        .byte => raw.len > 0 and raw[0] != 0xff,
        else => !isInvalid(base_type, raw, endian),
    };
}

fn readBitsLe(bytes: []const u8, bit_offset: usize, bit_count: usize) u64 {
    var value: u64 = 0;
    var index: usize = 0;
    while (index < bit_count) : (index += 1) {
        const source_bit = bit_offset + index;
        const byte_index = source_bit / 8;
        if (byte_index >= bytes.len) break;
        const bit_index: u3 = @intCast(source_bit % 8);
        const bit = (bytes[byte_index] >> bit_index) & 1;
        value |= @as(u64, bit) << @intCast(index);
    }
    return value;
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

fn sourceTypeName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "ant",
        1 => "antplus",
        2 => "bluetooth",
        3 => "bluetooth_low_energy",
        4 => "wifi",
        5 => "local",
        else => null,
    };
}

fn localDeviceTypeName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "gps",
        1 => "glonass",
        2 => "gps_glonass",
        3 => "accelerometer",
        4 => "barometer",
        5 => "temperature",
        10 => "whr",
        12 => "sensor_hub",
        else => null,
    };
}

fn antNetworkName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "public",
        1 => "antplus",
        2 => "antfs",
        3 => "private",
        else => null,
    };
}

fn workoutCapabilitiesName(value: u64) ?[]const u8 {
    return switch (value) {
        1 => "interval",
        2 => "custom",
        4 => "fitness_equipment",
        8 => "firstbeat",
        16 => "new_leaf",
        32 => "tcx",
        128 => "speed",
        256 => "heart_rate",
        512 => "distance",
        1024 => "cadence",
        2048 => "power",
        4096 => "grade",
        8192 => "resistance",
        16384 => "protected",
        else => null,
    };
}

fn autoActivityDetectName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "none",
        1 => "running",
        2 => "cycling",
        4 => "swimming",
        8 => "walking",
        32 => "elliptical",
        1024 => "sedentary",
        else => null,
    };
}

fn backlightModeName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "off",
        1 => "manual",
        2 => "key_and_messages",
        3 => "auto_brightness",
        4 => "smart_notifications",
        5 => "key_and_messages_night",
        6 => "key_and_messages_and_smart_notifications",
        else => null,
    };
}

fn antplusDeviceTypeName(value: u64) ?[]const u8 {
    return switch (value) {
        1 => "antfs",
        11 => "bike_power",
        12 => "environment_sensor_legacy",
        15 => "multi_sport_speed_distance",
        16 => "control",
        17 => "fitness_equipment",
        18 => "blood_pressure",
        19 => "geocache_node",
        20 => "light_electric_vehicle",
        25 => "env_sensor",
        26 => "racquet",
        27 => "control_hub",
        31 => "muscle_oxygen",
        34 => "shifting",
        35 => "bike_light_main",
        36 => "bike_light_shared",
        38 => "exd",
        40 => "bike_radar",
        46 => "bike_aero",
        119 => "weight_scale",
        120 => "heart_rate",
        121 => "bike_speed_cadence",
        122 => "bike_cadence",
        123 => "bike_speed",
        124 => "stride_speed_distance",
        else => null,
    };
}

fn sideName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "right",
        1 => "left",
        else => null,
    };
}

fn batteryStatusName(value: u64) ?[]const u8 {
    return switch (value) {
        1 => "new",
        2 => "good",
        3 => "ok",
        4 => "low",
        5 => "critical",
        6 => "charging",
        7 => "unknown",
        else => null,
    };
}

fn timeModeName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "hour12",
        1 => "hour24",
        2 => "military",
        3 => "hour_12_with_seconds",
        4 => "hour_24_with_seconds",
        5 => "utc",
        else => null,
    };
}

fn dateModeName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "day_month",
        1 => "month_day",
        else => null,
    };
}

fn activityClassName(value: u64) ?[]const u8 {
    return switch (value) {
        100 => "level_max",
        127 => "level",
        128 => "athlete",
        else => null,
    };
}

fn displayMeasureName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "metric",
        1 => "statute",
        2 => "nautical",
        else => null,
    };
}

fn fitBaseUnitName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "other",
        1 => "kilogram",
        2 => "pound",
        else => null,
    };
}

fn displayHeartName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "bpm",
        1 => "max",
        2 => "reserve",
        else => null,
    };
}

fn displayPowerName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "watts",
        1 => "percent_ftp",
        else => null,
    };
}

fn hrZoneCalcName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "custom",
        1 => "percent_max_hr",
        2 => "percent_hrr",
        3 => "percent_lthr",
        else => null,
    };
}

fn pwrZoneCalcName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "custom",
        1 => "percent_ftp",
        else => null,
    };
}

fn displayPositionName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "degree",
        1 => "degree_minute",
        2 => "degree_minute_second",
        3 => "austrian_grid",
        4 => "british_grid",
        5 => "dutch_grid",
        6 => "hungarian_grid",
        7 => "finnish_grid",
        8 => "german_grid",
        9 => "icelandic_grid",
        10 => "indonesian_equatorial",
        11 => "indonesian_irian",
        12 => "indonesian_southern",
        13 => "india_zone_0",
        14 => "india_zone_IA",
        15 => "india_zone_IB",
        16 => "india_zone_IIA",
        17 => "india_zone_IIB",
        18 => "india_zone_IIIA",
        19 => "india_zone_IIIB",
        20 => "india_zone_IVA",
        21 => "india_zone_IVB",
        22 => "irish_transverse",
        23 => "irish_grid",
        24 => "loran",
        25 => "maidenhead_grid",
        26 => "mgrs_grid",
        27 => "new_zealand_grid",
        28 => "new_zealand_transverse",
        29 => "qatar_grid",
        30 => "modified_swedish_grid",
        31 => "swedish_grid",
        32 => "south_african_grid",
        33 => "swiss_grid",
        34 => "taiwan_grid",
        35 => "united_states_grid",
        36 => "utm_ups_grid",
        37 => "west_malayan",
        38 => "borneo_rso",
        39 => "estonian_grid",
        40 => "latvian_grid",
        41 => "swedish_ref_99_grid",
        else => null,
    };
}

fn intensityName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "active",
        1 => "rest",
        2 => "warmup",
        3 => "cooldown",
        4 => "recovery",
        5 => "interval",
        6 => "other",
        else => null,
    };
}

fn wktStepDurationName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "time",
        1 => "distance",
        2 => "hr_less_than",
        3 => "hr_greater_than",
        4 => "calories",
        5 => "open",
        6 => "repeat_until_steps_cmplt",
        7 => "repeat_until_time",
        8 => "repeat_until_distance",
        9 => "repeat_until_calories",
        10 => "repeat_until_hr_less_than",
        11 => "repeat_until_hr_greater_than",
        12 => "repeat_until_power_less_than",
        13 => "repeat_until_power_greater_than",
        14 => "power_less_than",
        15 => "power_greater_than",
        16 => "training_peaks_tss",
        17 => "repeat_until_power_last_lap_less_than",
        18 => "repeat_until_max_power_last_lap_less_than",
        19 => "power_3s_less_than",
        20 => "power_10s_less_than",
        21 => "power_30s_less_than",
        22 => "power_3s_greater_than",
        23 => "power_10s_greater_than",
        24 => "power_30s_greater_than",
        25 => "power_lap_less_than",
        26 => "power_lap_greater_than",
        27 => "repeat_until_training_peaks_tss",
        28 => "repetition_time",
        29 => "reps",
        31 => "time_only",
        else => null,
    };
}

fn wktStepTargetName(value: u64) ?[]const u8 {
    return switch (value) {
        0 => "speed",
        1 => "heart_rate",
        2 => "open",
        3 => "cadence",
        4 => "power",
        5 => "grade",
        6 => "resistance",
        7 => "power_3s",
        8 => "power_10s",
        9 => "power_30s",
        10 => "power_lap",
        11 => "swim_stroke",
        12 => "speed_lap",
        13 => "heart_rate_lap",
        else => null,
    };
}

fn fileTypeName(value: u8) []const u8 {
    return switch (value) {
        1 => "device",
        2 => "settings",
        3 => "sport",
        4 => "activity",
        5 => "workout",
        6 => "course",
        7 => "schedules",
        9 => "weight",
        10 => "totals",
        11 => "goals",
        14 => "blood_pressure",
        15 => "monitoring_a",
        20 => "activity_summary",
        28 => "monitoring_daily",
        32 => "monitoring_b",
        34 => "segment",
        35 => "segment_list",
        40 => "exd_configuration",
        247 => "mfg_range_min",
        254 => "mfg_range_max",
        else => "unknown",
    };
}

fn manufacturerName(value: u64) ?[]const u8 {
    return switch (value) {
        1 => "garmin",
        2 => "garmin_fr405_antfs",
        3 => "zephyr",
        4 => "dayton",
        5 => "idt",
        6 => "srm",
        7 => "quarq",
        8 => "ibike",
        9 => "saris",
        10 => "spark_hk",
        11 => "tanita",
        12 => "echowell",
        13 => "dynastream_oem",
        15 => "dynastream",
        51 => "4iiiis",
        89 => "tacx",
        263 => "favero_electronics",
        else => null,
    };
}

fn addManufacturerPair(record: VALUE, value: u64) void {
    if (manufacturerName(value)) |name| {
        addPair(record, "manufacturer", rbString(name), "");
    } else {
        addPair(record, "manufacturer", rbInt(@intCast(value)), "");
    }
}

fn isGarminProductManufacturer(value: ?u64) bool {
    return switch (value orelse return false) {
        1, 13, 15, 89 => true,
        else => false,
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

fn addScaledPair(record: VALUE, field_name: []const u8, scalar: Scalar, scale: f64, offset: f64, units: []const u8) void {
    const value = scalar.toF64() orelse return;
    addPair(record, field_name, rbFloat(value / scale - offset), units);
}

fn rbSym(name: []const u8) VALUE {
    var buffer: [128]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buffer, "{s}", .{name}) catch unreachable;
    return c.rb_id2sym(c.rb_intern(z.ptr));
}

fn rbString(value: []const u8) VALUE {
    return c.rb_str_new(value.ptr, @intCast(value.len));
}

fn rbLocalDateTime(value: u64) VALUE {
    const time_class = c.rb_const_get(c.rb_cObject, c.rb_intern("Time"));
    const local_epoch = c.rb_funcall(
        time_class,
        c.rb_intern("local"),
        6,
        rbInt(1989),
        rbInt(12),
        rbInt(31),
        rbInt(0),
        rbInt(0),
        rbInt(0),
    );
    const timestamp = c.rb_funcall(local_epoch, c.rb_intern("+"), 1, rbInt(@intCast(value)));
    return c.rb_funcall(timestamp, c.rb_intern("to_i"), 0);
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

    const gc_was_disabled = c.rb_gc_disable();
    defer {
        if (gc_was_disabled == 0) _ = c.rb_gc_enable();
    }

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
