pub fn mutateLineup(
    changes: logic.Changes.Subset(.{
        logic.Changes.Lineup,
    }),
    properties: logic.Properties.Mutable(.{
        logic.Properties.Lineup,
    }),
) !void {
    for (changes.lineups) |change|
        properties.lineup.meta[change.slot.toIndex()] = change.meta;
}

const logic = @import("../../logic.zig");
const mutators = @import("../mutators.zig");
const std = @import("std");
