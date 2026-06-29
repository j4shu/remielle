pub const slots = 20;
pub const avatar_slots = 3;
pub const Name = rmmem.LimitedString(14);

meta: [slots]Meta,

pub const init: Lineup = std.mem.zeroes(Lineup);

pub const Meta = struct {
    name: Name,
    avatar_ids: [avatar_slots]OptionalID,
    buddy_id: OptionalID,
};

pub const Slot = enum(u8) {
    _,

    pub fn fromInt(lineup_id: u32) ?Slot {
        if (lineup_id < 1 or lineup_id > slots)
            return null;

        return @enumFromInt(@as(u8, @intCast(lineup_id)));
    }

    pub fn toIndex(lineup_id: Slot) u8 {
        return @intFromEnum(lineup_id) - 1;
    }
};

pub const OptionalID = enum(u32) {
    none = 0,
    _,

    pub fn unwrap(o: OptionalID) ?u32 {
        return switch (o) {
            .none => null,
            _ => |id| @intFromEnum(id),
        };
    }
};

const rmmem = @import("rmmem");
const std = @import("std");
const Lineup = @This();
