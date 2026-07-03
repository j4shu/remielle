//! edit-save — overwrite the W-Engines + drive discs in a remielle PlayerSave
//! (`Persistent/LocalStorage/USD_*.bin`) with hand-crafted loadouts defined in
//! `tools/builds/builds.zon`, and auto-equip them onto their characters.
//!
//! `tools/builds/builds.zon` is grouped per character: each block names an `.avatar`
//! (a friendly name from the `Avatar` enum below), a `.weapon` (a friendly name
//! from the `Weapon` enum), and its 6 slot templates. One maxed W-Engine is made
//! for the named weapon, and for each slot one disc is generated for the `.set` it
//! names (a friendly name from the `Set` enum), with the exact main stat + 4
//! substats you specified.
//!
//! `builds.zon` is the source of truth: the whole `weapon` and `equip` inventories
//! are replaced with exactly these items, each inventory renumbered with fresh uids
//! from 0 (one W-Engine per character; six discs per character), every avatar's
//! equipped-weapon and equipped-disc references are cleared, and then each listed
//! character is auto-equipped with its W-Engine + 6 discs — so after a run you just
//! log in and everyone already wears their build. Characters not listed in
//! `builds.zon` end up with no weapon and empty disc slots, and re-running is
//! idempotent. A listed character that isn't owned in the save is reported and
//! skipped (its items still land in the inventory).
//!
//! It reuses remielle's own `rmpb` decode/encode and mirrors the value encoding
//! of the in-game random generator (gamesv/src/logic/Properties.zig), so whatever
//! the spec asks for is exactly what shows up in game.
//!
//! Run while the game server is stopped / you are logged out — otherwise the next
//! disconnect/shutdown save will overwrite the edit.
//!
//! All of tools/builds/builds.zon's rules are checked at comptime, so a bad spec fails
//! to compile before any save is read.
//!
//! Usage (from the `remielle` directory):
//!   zig build edit-save -- Persistent/LocalStorage/USD_666.bin
//!   zig build edit-save                 # defaults to USD_666.bin

const default_path = "Persistent/LocalStorage/USD_666.bin";

// Comptime branch budget for resolving the spec. Bumped well past the default because
// building `weapon_ids` scans all of WeaponTemplateTb (~190 entries); the other comptime
// sites (the spec lowering, `main`) reuse the same value to keep them in lockstep.
const eval_quota = 20000;

pub fn main(init: Init) !void {
    @setEvalBranchQuota(eval_quota);

    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const path = if (args.len >= 2) args[1] else default_path;

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err|
        fail(io, "error: couldn't read '{s}': {t}\n", .{ path, err });

    var reader = Io.Reader.fixed(bytes);
    var save = rmpb.decode(.stable, rmpb.stable.PlayerSave, arena, &reader) catch |err|
        fail(io, "error: failed to decode PlayerSave from '{s}': {t}\n", .{ path, err });

    // Build the disc inventory: 6 discs per character, each for its slot's `.set`.
    // Assign sequential uids `0..N-1` and remember, per character, the 6 uids in
    // slot order so we can auto-equip them onto that avatar afterward.
    const total = character_templates.len * 6;
    var items: std.ArrayList(rmpb.stable.EquipItemSave) = try .initCapacity(arena, total);
    var equip_uids: [character_templates.len][6]u32 = undefined;
    var uid: u32 = 0;
    inline for (character_templates, 0..) |c, ci| {
        inline for (c.discs, 0..) |tmpl, si| {
            var props: std.ArrayList(rmpb.stable.EquipProperty) = try .initCapacity(arena, 5);
            inline for (tmpl.props) |p|
                props.appendAssumeCapacity(.{ .key = p.key, .base_value = p.base, .add_value = p.add });
            items.appendAssumeCapacity(.{
                .uid = uid,
                // equip_id = suit_id + 40 + slot  (the +40 = S-rank tier).
                .id = tmpl.set + @as(u32, 40 + tmpl.slot),
                .level = 15,
                .star = 5,
                .properties = props,
            });
            equip_uids[ci][si] = uid;
            uid += 1;
        }
    }

    // Replace the whole disc inventory (builds.zon is the source of truth).
    if (save.equip) |*eq| {
        eq.items = items;
    } else {
        save.equip = .{ .items = items };
    }

    // Build the W-Engine inventory: one maxed copy per character, raw uid = ci.
    // This is a separate inventory from discs, so its uids start fresh at 0.
    var weapon_items: std.ArrayList(rmpb.stable.WeaponItemSave) =
        try .initCapacity(arena, character_templates.len);
    inline for (character_templates, 0..) |c, ci| {
        weapon_items.appendAssumeCapacity(.{
            .uid = @intCast(ci),
            .id = c.weapon_id,
            .level = 60,
            .star = 5,
            .refine = 5,
        });
    }

    // Replace the whole weapon inventory (builds.zon is the source of truth).
    if (save.weapon) |*wp| {
        wp.items = weapon_items;
    } else {
        save.weapon = .{ .items = weapon_items };
    }

    // Auto-equip. Clear EVERY avatar's equipped-weapon + equipped-disc references
    // first — a stale `uid + base` left on some other avatar could collide with a
    // freshly generated uid and cross-equip the wrong character — then set the
    // managed ones. An avatar's disc slot stores `uid + equipment_uid_base` and its
    // `weapon_uid` stores `uid + weapon_uid_base` (not the raw uids; 0 = no weapon).
    // A listed character that isn't owned in the save is recorded as skipped (its
    // items still exist in the inventories; it just isn't wearing them).
    var equipped: [character_templates.len]bool = .{false} ** character_templates.len;
    if (save.avatar) |*av| {
        for (av.items.items) |*a| {
            a.equipment_uids = .empty;
            a.weapon_uid = 0;
        }
        inline for (character_templates, 0..) |c, ci| {
            for (av.items.items) |*a| {
                if (a.id != c.avatar_id) continue;
                var uids: std.ArrayList(u32) = try .initCapacity(arena, 6);
                for (equip_uids[ci]) |u| uids.appendAssumeCapacity(u + equipment_uid_base);
                a.equipment_uids = uids;
                a.weapon_uid = @as(u32, @intCast(ci)) + weapon_uid_base;
                equipped[ci] = true;
                break;
            }
        }
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
    var buf: [16 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try w.print("edit-save: wrote {d} W-Engines + {d} discs to {s}\n", .{ character_templates.len, total, path });
    try w.print("backup:    {s} ({d} bytes)\n", .{ bak_path, bytes.len });
    try w.print("new size:  {d} bytes\n\n", .{out_bytes.len});
    inline for (character_templates, 0..) |c, ci| {
        if (equipped[ci])
            try w.print("  .{s} (avatar {d})\n", .{ c.avatar_name, c.avatar_id })
        else
            try w.print("  .{s} (avatar {d})  - NOT owned (added to inventory, not equipped)\n", .{ c.avatar_name, c.avatar_id });
    }
    try w.flush();
}

// ── Spec → comptime disc templates ──────────────────────────────────────────

const spec = @import("builds");
const suit_table = @import("EquipmentSuitTemplateTb");
const weapon_table = @import("WeaponTemplateTb");

// Friendly name tables shared with tools/builds/inspect-save.zig so the writer and the reader
// can never disagree about a name: Set (set name → suit id), Avatar (character name →
// avatar id), and Weapon (W-Engine name → weapon id).
const zzz = @import("zzz_names.zig");
const Set = zzz.Set;
const Avatar = zzz.Avatar;
const Weapon = zzz.Weapon;

// Gear-uid encoding bases (an avatar reference stores `raw uid + base`); see the docs in
// tools/builds/zzz_names.zig. Shared so the writer and inspect-save can never disagree.
const equipment_uid_base = zzz.equipment_uid_base;
const weapon_uid_base = zzz.weapon_uid_base;

const PropVal = struct { key: u32, base: u32, add: u32 };
const DiscTemplate = struct { slot: u8, set: u32, set_name: []const u8, props: [5]PropVal };
const CharacterTemplate = struct {
    avatar_id: u32,
    avatar_name: []const u8,
    weapon_id: u32,
    weapon_name: []const u8,
    discs: [6]DiscTemplate,
};

/// Per-character W-Engine + disc builds resolved + validated at compile time from
/// `tools/builds/builds.zon`. Each character's `.slots` lower to 6 `DiscTemplate`s placed
/// by slot position (`discs[slot - 1]`), so index N-1 is always slot N.
const character_templates = blk: {
    @setEvalBranchQuota(eval_quota);
    const chars = spec.characters;
    const n = @typeInfo(@TypeOf(chars)).@"struct".fields.len;
    var out: [n]CharacterTemplate = undefined;
    for (chars, 0..) |centry, i| out[i] = buildCharacter(centry);
    break :blk out;
};

/// Validate one character block: resolve its `.avatar` (a friendly `Avatar` name)
/// and `.weapon` (a friendly `Weapon` name, cross-checked against WeaponTemplateTb),
/// and lower its 6 `.slots`, requiring exactly slots 1..6 with no duplicates.
fn buildCharacter(comptime centry: anytype) CharacterTemplate {
    const C = @TypeOf(centry);
    if (!@hasField(C, "avatar"))
        @compileError("each character requires an .avatar (a name from the Avatar enum)");
    if (!@hasField(C, "weapon"))
        @compileError("each character requires a .weapon (a name from the Weapon enum)");
    if (!@hasField(C, "slots"))
        @compileError("each character requires .slots");

    const avatar_id: u32 = @intFromEnum(@field(Avatar, @tagName(centry.avatar)));
    const avatar_name: []const u8 = @tagName(centry.avatar);

    const weapon_id: u32 = @intFromEnum(@field(Weapon, @tagName(centry.weapon)));
    if (!weaponExists(weapon_id))
        @compileError(std.fmt.comptimePrint(
            "weapon .{s} (id {d}) is not present in WeaponTemplateTb",
            .{ @tagName(centry.weapon), weapon_id },
        ));
    const weapon_name: []const u8 = @tagName(centry.weapon);

    const slots = centry.slots;
    const sn = @typeInfo(@TypeOf(slots)).@"struct".fields.len;
    if (sn != 6)
        @compileError(std.fmt.comptimePrint("character .{s} must have exactly 6 slots, got {d}", .{ avatar_name, sn }));

    var discs: [6]DiscTemplate = undefined;
    var seen = [_]bool{false} ** 6;
    for (slots) |entry| {
        const t = buildOne(entry);
        if (seen[t.slot - 1])
            @compileError(std.fmt.comptimePrint("character .{s} has a duplicate slot {d}", .{ avatar_name, t.slot }));
        seen[t.slot - 1] = true;
        discs[t.slot - 1] = t;
    }
    for (seen, 0..) |s, idx|
        if (!s) @compileError(std.fmt.comptimePrint("character .{s} is missing slot {d}", .{ avatar_name, idx + 1 }));

    return .{
        .avatar_id = avatar_id,
        .avatar_name = avatar_name,
        .weapon_id = weapon_id,
        .weapon_name = weapon_name,
        .discs = discs,
    };
}

/// Every equipment set id, mirrored from `EquipmentSuitTemplateTb.zon`.
const suit_ids = blk: {
    const n = @typeInfo(@TypeOf(suit_table)).@"struct".fields.len;
    var out: [n]u32 = undefined;
    for (suit_table, 0..) |s, i| out[i] = s.id;
    break :blk out;
};

fn suitExists(id: u32) bool {
    for (suit_ids) |s| if (s == id) return true;
    return false;
}

/// Every W-Engine id, mirrored from `WeaponTemplateTb.zon` (its `item_id`).
const weapon_ids = blk: {
    @setEvalBranchQuota(eval_quota);
    const n = @typeInfo(@TypeOf(weapon_table)).@"struct".fields.len;
    var out: [n]u32 = undefined;
    for (weapon_table, 0..) |wp, i| out[i] = wp.item_id;
    break :blk out;
};

fn weaponExists(id: u32) bool {
    for (weapon_ids) |w| if (w == id) return true;
    return false;
}

/// Validate one slot template and lower it to fixed `base_value`/`add_value`s.
/// All rule violations are compile errors (strict — mirrors the real game rules
/// encoded in `rand_table`).
fn buildOne(comptime entry: anytype) DiscTemplate {
    const E = @TypeOf(entry);
    const slot: comptime_int = entry.slot;
    if (slot < 1 or slot > 6)
        @compileError(std.fmt.comptimePrint("slot must be 1..6, got {d}", .{slot}));

    // Resolve the required target set (a friendly name from the `Set` enum).
    if (!@hasField(E, "set"))
        @compileError(std.fmt.comptimePrint("slot {d} requires a .set", .{slot}));
    const set_id: u32 = @intFromEnum(@field(Set, @tagName(entry.set)));
    if (!suitExists(set_id))
        @compileError(std.fmt.comptimePrint(
            "set .{s} (id {d}) is not present in EquipmentSuitTemplateTb",
            .{ @tagName(entry.set), set_id },
        ));
    const set_name: []const u8 = @tagName(entry.set);

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

    return .{ .slot = @as(u8, slot), .set = set_id, .set_name = set_name, .props = props };
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
    HpFlat,
    AtkFlat,
    DefFlat,
    HpPct,
    AtkPct,
    DefPct,
    CritRate,
    CritDmg,
    AnomProf,
    PenFlat,
    PenRatio,
    PhysDmg,
    FireDmg,
    IceDmg,
    ElecDmg,
    EtherDmg,
    WindDmg,
    EnergyRegen,
    AnomMastery,
    Impact,
};

const Row = struct { key: u32, main_base: u32, sub_base: ?u32, main_slots: []const u8 };

fn row(stat: Stat) Row {
    return switch (stat) {
        .HpFlat => .{ .key = 11103, .main_base = 550, .sub_base = 112, .main_slots = &.{1} },
        .AtkFlat => .{ .key = 12103, .main_base = 79, .sub_base = 19, .main_slots = &.{2} },
        .DefFlat => .{ .key = 13103, .main_base = 46, .sub_base = 15, .main_slots = &.{3} },
        .HpPct => .{ .key = 11102, .main_base = 750, .sub_base = 300, .main_slots = &.{ 4, 5, 6 } },
        .AtkPct => .{ .key = 12102, .main_base = 750, .sub_base = 300, .main_slots = &.{ 4, 5, 6 } },
        .DefPct => .{ .key = 13102, .main_base = 1200, .sub_base = 480, .main_slots = &.{ 4, 5, 6 } },
        .CritRate => .{ .key = 20103, .main_base = 600, .sub_base = 240, .main_slots = &.{4} },
        .CritDmg => .{ .key = 21103, .main_base = 1200, .sub_base = 480, .main_slots = &.{4} },
        .AnomProf => .{ .key = 31203, .main_base = 23, .sub_base = 9, .main_slots = &.{4} },
        .PenFlat => .{ .key = 23203, .main_base = 0, .sub_base = 9, .main_slots = &.{} },
        .PenRatio => .{ .key = 23103, .main_base = 600, .sub_base = null, .main_slots = &.{5} },
        .PhysDmg => .{ .key = 31503, .main_base = 750, .sub_base = null, .main_slots = &.{5} },
        .FireDmg => .{ .key = 31603, .main_base = 750, .sub_base = null, .main_slots = &.{5} },
        .IceDmg => .{ .key = 31703, .main_base = 750, .sub_base = null, .main_slots = &.{5} },
        .ElecDmg => .{ .key = 31803, .main_base = 750, .sub_base = null, .main_slots = &.{5} },
        .EtherDmg => .{ .key = 31903, .main_base = 750, .sub_base = null, .main_slots = &.{5} },
        .WindDmg => .{ .key = 32303, .main_base = 750, .sub_base = null, .main_slots = &.{5} },
        .EnergyRegen => .{ .key = 30502, .main_base = 1500, .sub_base = null, .main_slots = &.{6} },
        .AnomMastery => .{ .key = 31402, .main_base = 750, .sub_base = null, .main_slots = &.{6} },
        .Impact => .{ .key = 12202, .main_base = 450, .sub_base = null, .main_slots = &.{6} },
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
