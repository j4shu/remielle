pub fn modLineup(
    message: Message(pb.ModLineupCsReq),
    changes: Changes.Builder(.{
        Changes.Lineup,
    }),
    response: Response(pb.ModLineupScRsp),
) !void {
    const lineup_data = message.data.lineup orelse return response.fail(1);
    var lineups: std.ArrayList(Changes.Lineup) = try .initCapacity(changes.allocator, lineup_data.lineup_list.items.len);

    for (lineup_data.lineup_list.items) |lineup| {
        if (lineup.avatar_list.items.len > 3 or
            lineup.buddy_list.items.len > 1) return response.fail(1);

        var meta: Properties.Lineup.Meta = .{
            .name = Properties.Lineup.Name.fromSlice(lineup.name) catch return response.fail(1),
            .avatar_ids = @splat(.none),
            .buddy_id = .none,
        };

        for (lineup.avatar_list.items, 0..) |avatar, i| meta.avatar_ids[i] = @enumFromInt(avatar.avatar_id);
        if (lineup.buddy_list.items.len == 1) meta.buddy_id = @enumFromInt(lineup.buddy_list.items[0].buddy_id);

        lineups.appendAssumeCapacity(.{
            .slot = Properties.Lineup.Slot.fromInt(lineup.lineup_id) orelse return response.fail(1),
            .meta = meta,
        });
    }

    changes.insert(lineups.toOwnedSliceAssert());
    response.set(.init);
}

pub fn setLineupName(
    message: Message(pb.SetLineupNameCsReq),
    properties: Properties.Immutable(.{
        Properties.Lineup,
    }),
    changes: Changes.Builder(.{
        Changes.Lineup,
    }),
    response: Response(pb.SetLineupNameScRsp),
) !void {
    var lineups = try changes.allocator.alloc(Changes.Lineup, 1);
    lineups[0].slot = Properties.Lineup.Slot.fromInt(message.data.lineup_id) orelse return response.fail(1);
    lineups[0].meta = properties.lineup.meta[lineups[0].slot.toIndex()];
    lineups[0].meta.name.set(message.data.name) catch return response.fail(1);

    changes.insert(lineups);
    response.set(.init);
}

const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
