//! edit-save — overwrite the drive discs in a remielle PlayerSave
//! (`Persistent/LocalStorage/USD_*.bin`) with hand-crafted discs defined in
//! `tools/discs.zon`.
//!
//! For each slot template in the spec, one disc is generated for **every**
//! equipment set, with the exact main stat + 4 substats you specified. The whole
//! `equip` inventory is replaced (fresh uids `0..N-1`) and every agent's equipped
//! disc references are cleared, so you re-equip in game.
//!
//! It reuses remielle's own `rmpb` decode/encode and mirrors the value encoding
//! of the in-game random generator (gamesv/src/logic/Properties.zig), so whatever
//! the spec asks for is exactly what shows up in game.
//!
//! Run while the game server is stopped / you are logged out — otherwise the next
//! disconnect/shutdown save will overwrite the edit.
//!
//! Usage (from the `remielle` directory):
//!   zig build check-discs               # validate tools/discs.zon only (no save touched)
//!   zig build edit-save -- Persistent/LocalStorage/USD_666.bin
//!   zig build edit-save                 # defaults to USD_666.bin

const default_path = "Persistent/LocalStorage/USD_666.bin";

pub fn main(init: Init) !void {
    @setEvalBranchQuota(20000);

    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const path = if (args.len >= 2) args[1] else default_path;

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err|
        fail(io, "error: couldn't read '{s}': {t}\n", .{ path, err });

    var reader = Io.Reader.fixed(bytes);
    var save = rmpb.decode(.stable, rmpb.stable.PlayerSave, arena, &reader) catch |err|
        fail(io, "error: failed to decode PlayerSave from '{s}': {t}\n", .{ path, err });

    // Build the disc list: each comptime slot template × every suit id.
    const total = suit_ids.len * disc_templates.len;
    var items: std.ArrayList(rmpb.stable.EquipItemSave) = try .initCapacity(arena, total);
    var uid: u32 = 0;
    for (suit_ids) |suit| {
        inline for (disc_templates) |tmpl| {
            var props: std.ArrayList(rmpb.stable.EquipProperty) = try .initCapacity(arena, 5);
            inline for (tmpl.props) |p|
                props.appendAssumeCapacity(.{ .key = p.key, .base_value = p.base, .add_value = p.add });
            items.appendAssumeCapacity(.{
                .uid = uid,
                // equip_id = suit_id + 40 + slot  (the +40 = S-rank tier).
                .id = suit + @as(u32, 40 + tmpl.slot),
                .level = 15,
                .star = 5,
                .properties = props,
            });
            uid += 1;
        }
    }

    // Replace the whole inventory.
    if (save.equip) |*eq| {
        eq.items = items;
    } else {
        save.equip = .{ .items = items };
    }

    // Drop every agent's now-stale equipped-disc references.
    if (save.avatar) |*av| {
        for (av.items.items) |*a| a.equipment_uids = .empty;
    }

    // Encode first, so an encode failure never touches the files. Only then back
    // up the original and overwrite it.
    const out_bytes = rmpb.encodeAlloc(.stable, arena, save) catch |err|
        fail(io, "error: failed to encode PlayerSave: {t}\n", .{err});

    const cwd = Io.Dir.cwd();
    const bak_path = try std.fmt.allocPrint(arena, "{s}.bak", .{path});
    cwd.writeFile(io, .{ .sub_path = bak_path, .data = bytes }) catch |err|
        fail(io, "error: failed to write backup '{s}': {t}\n", .{ bak_path, err });
    cwd.writeFile(io, .{ .sub_path = path, .data = out_bytes }) catch |err|
        fail(io, "error: failed to write '{s}': {t}\n", .{ path, err });

    // Summary.
    var buf: [8 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try w.print("edit-save: wrote {d} discs ({d} sets x {d} slot templates) to {s}\n", .{
        total, suit_ids.len, disc_templates.len, path,
    });
    try w.print("backup:    {s} ({d} bytes)\n", .{ bak_path, bytes.len });
    try w.print("new size:  {d} bytes\n\n", .{out_bytes.len});
    try w.writeAll("slot templates (applied to every set):\n");
    inline for (disc_templates) |tmpl| {
        try w.print("  slot {d}  main {s}", .{ tmpl.slot, propName(tmpl.props[0].key) });
        inline for (1..5) |k| {
            const p = tmpl.props[k];
            try w.print("  +{s}(+{d})", .{ propName(p.key), p.add - 1 });
        }
        try w.writeByte('\n');
    }
    try w.flush();
}

// ── Spec → comptime disc templates ──────────────────────────────────────────

const spec = @import("discs");
const suit_table = @import("EquipmentSuitTemplateTb");

const PropVal = struct { key: u32, base: u32, add: u32 };
const DiscTemplate = struct { slot: u8, props: [5]PropVal };

/// Slot templates resolved + validated at compile time from `tools/discs.zon`.
const disc_templates = blk: {
    const slots = spec.slots;
    const n = @typeInfo(@TypeOf(slots)).@"struct".fields.len;
    var out: [n]DiscTemplate = undefined;
    for (slots, 0..) |entry, i| out[i] = buildOne(entry);
    break :blk out;
};

/// Every equipment set id, mirrored from `EquipmentSuitTemplateTb.zon`.
const suit_ids = blk: {
    const n = @typeInfo(@TypeOf(suit_table)).@"struct".fields.len;
    var out: [n]u32 = undefined;
    for (suit_table, 0..) |s, i| out[i] = s.id;
    break :blk out;
};

/// Validate one slot template and lower it to fixed `base_value`/`add_value`s.
/// All rule violations are compile errors (strict — mirrors the real game rules
/// encoded in `rand_table`).
fn buildOne(comptime entry: anytype) DiscTemplate {
    const E = @TypeOf(entry);
    const slot: comptime_int = entry.slot;
    if (slot < 1 or slot > 6)
        @compileError(std.fmt.comptimePrint("slot must be 1..6, got {d}", .{slot}));

    // Resolve main stat: explicit for any slot, auto HP/ATK/DEF flat for 1-3.
    const main_stat: Stat = if (@hasField(E, "main"))
        @field(Stat, @tagName(entry.main))
    else switch (slot) {
        1 => .HpFlat,
        2 => .AtkFlat,
        3 => .DefFlat,
        else => @compileError(std.fmt.comptimePrint("slot {d} requires an explicit .main stat", .{slot})),
    };

    const mrow = row(main_stat);
    if (!contains(mrow.main_slots, slot))
        @compileError(@tagName(main_stat) ++ std.fmt.comptimePrint(" is not a legal main stat for slot {d}", .{slot}));

    const subs = entry.subs;
    const sub_count = @typeInfo(@TypeOf(subs)).@"struct".fields.len;
    if (sub_count != 4)
        @compileError(std.fmt.comptimePrint("slot {d} must have exactly 4 substats, got {d}", .{ slot, sub_count }));

    var props: [5]PropVal = undefined;
    // Main: base = main_base_value, add_value = 1.
    props[0] = .{ .key = mrow.key, .base = mrow.main_base, .add = 1 };

    var upgrade_sum: comptime_int = 0;
    var seen: [4]Stat = undefined;
    inline for (subs, 0..) |sub, j| {
        const sstat: Stat = @field(Stat, @tagName(sub[0]));
        const upg: comptime_int = sub[1];
        if (upg < 0)
            @compileError(@tagName(sstat) ++ ": upgrades cannot be negative");

        const srow = row(sstat);
        if (srow.sub_base == null)
            @compileError(@tagName(sstat) ++ " can never be a substat (it is main-only)");
        if (sstat == main_stat)
            @compileError(@tagName(sstat) ++ " is used as both the main stat and a substat");
        for (seen[0..j]) |prev|
            if (prev == sstat) @compileError("duplicate substat: " ++ @tagName(sstat));
        seen[j] = sstat;

        upgrade_sum += upg;
        // Sub: base = rand_base_value, add_value = 1 + upgrades.
        props[1 + j] = .{ .key = srow.key, .base = srow.sub_base.?, .add = 1 + @as(u32, upg) };
    }
    if (upgrade_sum != 5)
        @compileError(std.fmt.comptimePrint("slot {d} substat upgrades must sum to 5, got {d}", .{ slot, upgrade_sum }));

    return .{ .slot = @as(u8, slot), .props = props };
}

fn contains(slots: []const u8, slot: comptime_int) bool {
    for (slots) |s| if (s == slot) return true;
    return false;
}

// ── Stat vocabulary ─────────────────────────────────────────────────────────
// Mirrored from `rand_table` in gamesv/src/logic/Properties.zig:215-236.
//   main_slots  = the slots a stat may be a MAIN on ({} = sub-only)
//   sub_base    = null  ⇒ stat can NEVER be a substat (main-only / locked)

const Stat = enum {
    HpFlat,  AtkFlat,  DefFlat,
    HpPct,   AtkPct,   DefPct,
    CritRate, CritDmg, AnomProf,
    PenFlat,
    PenRatio, PhysDmg, FireDmg, IceDmg, ElecDmg, EtherDmg, WindDmg,
    EnergyRegen, AnomMastery, Impact,
};

const Row = struct { key: u32, main_base: u32, sub_base: ?u32, main_slots: []const u8 };

fn row(stat: Stat) Row {
    return switch (stat) {
        .HpFlat   => .{ .key = 11103, .main_base = 550,  .sub_base = 112,  .main_slots = &.{1} },
        .AtkFlat  => .{ .key = 12103, .main_base = 79,   .sub_base = 19,   .main_slots = &.{2} },
        .DefFlat  => .{ .key = 13103, .main_base = 46,   .sub_base = 15,   .main_slots = &.{3} },
        .HpPct    => .{ .key = 11102, .main_base = 750,  .sub_base = 300,  .main_slots = &.{ 4, 5, 6 } },
        .AtkPct   => .{ .key = 12102, .main_base = 750,  .sub_base = 300,  .main_slots = &.{ 4, 5, 6 } },
        .DefPct   => .{ .key = 13102, .main_base = 1200, .sub_base = 480,  .main_slots = &.{ 4, 5, 6 } },
        .CritRate => .{ .key = 20103, .main_base = 600,  .sub_base = 240,  .main_slots = &.{4} },
        .CritDmg  => .{ .key = 21103, .main_base = 1200, .sub_base = 480,  .main_slots = &.{4} },
        .AnomProf => .{ .key = 31203, .main_base = 23,   .sub_base = 9,    .main_slots = &.{4} },
        .PenFlat  => .{ .key = 23203, .main_base = 0,    .sub_base = 9,    .main_slots = &.{} },
        .PenRatio => .{ .key = 23103, .main_base = 600,  .sub_base = null, .main_slots = &.{5} },
        .PhysDmg  => .{ .key = 31503, .main_base = 750,  .sub_base = null, .main_slots = &.{5} },
        .FireDmg  => .{ .key = 31603, .main_base = 750,  .sub_base = null, .main_slots = &.{5} },
        .IceDmg   => .{ .key = 31703, .main_base = 750,  .sub_base = null, .main_slots = &.{5} },
        .ElecDmg  => .{ .key = 31803, .main_base = 750,  .sub_base = null, .main_slots = &.{5} },
        .EtherDmg => .{ .key = 31903, .main_base = 750,  .sub_base = null, .main_slots = &.{5} },
        .WindDmg  => .{ .key = 32303, .main_base = 750,  .sub_base = null, .main_slots = &.{5} },
        .EnergyRegen => .{ .key = 30502, .main_base = 1500, .sub_base = null, .main_slots = &.{6} },
        .AnomMastery => .{ .key = 31402, .main_base = 750,  .sub_base = null, .main_slots = &.{6} },
        .Impact      => .{ .key = 12202, .main_base = 450,  .sub_base = null, .main_slots = &.{6} },
    };
}

/// Friendly name for a property key (summary output only).
fn propName(key: u32) []const u8 {
    return switch (key) {
        11103 => "HpFlat",      11102 => "HpPct",
        12103 => "AtkFlat",     12102 => "AtkPct",     12202 => "Impact",
        13103 => "DefFlat",     13102 => "DefPct",
        20103 => "CritRate",    21103 => "CritDmg",
        23203 => "PenFlat",     23103 => "PenRatio",
        30502 => "EnergyRegen",
        31203 => "AnomProf",    31402 => "AnomMastery",
        31503 => "PhysDmg",     31603 => "FireDmg",    31703 => "IceDmg",
        31803 => "ElecDmg",     31903 => "EtherDmg",   32303 => "WindDmg",
        else => "?",
    };
}

fn fail(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    fw.interface.print(fmt, args) catch {};
    fw.interface.flush() catch {};
    std.process.exit(1);
}

const std = @import("std");
const rmpb = @import("rmpb");

const Io = std.Io;
const Init = std.process.Init;
