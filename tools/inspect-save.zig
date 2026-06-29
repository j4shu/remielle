//! inspect-save — read-only dump of the W-Engines + drive discs in a remielle
//! PlayerSave (`Persistent/LocalStorage/USD_*.bin`).
//!
//! It decodes the save with the same `rmpb` stable schema the game server uses and
//! prints:
//!   - the W-Engine inventory: each item's uid, weapon (resolved from its id),
//!     level/star/refine;
//!   - the drive-disc inventory: each item's uid, set (resolved from its id), slot,
//!     level/star, and main + sub stats;
//!   - per owned avatar, its equipped W-Engine and disc uids — decoded back to raw
//!     uids (an avatar's `weapon_uid` stores `uid + weapon_uid_base` and a disc slot
//!     stores `uid + equipment_uid_base`; the bases are defined in zzz_names.zig, from
//!     Weapon.Uid.base / Equipment.Uid.base), with any dangling reference (no matching
//!     inventory item) flagged.
//!
//! It NEVER writes — safe to run any time, even while logged in. Use it to confirm a
//! `zig build edit-save` run landed, or to debug what a save actually contains. The
//! `Set`/`Avatar`/`Weapon` name tables come from the same tools/zzz_names.zig that
//! edit-save writes from, so the names here always match what was written.
//!
//! Usage (from the `remielle` directory):
//!   zig build inspect-save                          # defaults to USD_666.bin
//!   zig build inspect-save -- Persistent/LocalStorage/USD_666.bin

const default_path = "Persistent/LocalStorage/USD_666.bin";

// An avatar's reference stores `uid + base` while the item itself stores the raw uid.
// Subtract to decode. Bases are defined once in zzz_names.zig (shared with edit-save).
const equipment_uid_base = zzz.equipment_uid_base;
const weapon_uid_base = zzz.weapon_uid_base;

pub fn main(init: Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const path = if (args.len >= 2) args[1] else default_path;

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err|
        fail(io, "error: couldn't read '{s}': {t}\n", .{ path, err });

    var reader = Io.Reader.fixed(bytes);
    const save = rmpb.decode(.stable, rmpb.stable.PlayerSave, arena, &reader) catch |err|
        fail(io, "error: failed to decode PlayerSave from '{s}': {t}\n", .{ path, err });

    var buf: [64 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    try w.print("inspect-save: {s} ({d} bytes)\n\n", .{ path, bytes.len });

    // ── W-Engine inventory ────────────────────────────────────────────────────
    var weapons_owned = std.AutoHashMap(u32, u32).init(arena); // uid → weapon id
    const weapon_items = if (save.weapon) |wp| wp.items.items else &.{};
    try w.print("W-Engines: {d}\n", .{weapon_items.len});
    for (weapon_items) |it| {
        try weapons_owned.put(it.uid, it.id);
        const name = zzz.weaponName(it.id) orelse "??";
        try w.print("  uid {d:>3}  {s} (id {d})  lv{d} *{d} R{d}\n", .{ it.uid, name, it.id, it.level, it.star, it.refine });
    }
    try w.writeByte('\n');

    // ── Drive-disc inventory ──────────────────────────────────────────────────
    var owned = std.AutoHashMap(u32, void).init(arena);
    const equip_items = if (save.equip) |eq| eq.items.items else &.{};
    try w.print("discs: {d}\n", .{equip_items.len});
    for (equip_items) |it| {
        try owned.put(it.uid, {});
        // id = suit_id + (10*rank + slot); suit_id is the hundreds (e.g. 32700).
        const suit_id = it.id - (it.id % 100);
        const within = it.id % 100;
        const slot = within % 10;
        const set = zzz.setName(suit_id) orelse "??";
        try w.print("  uid {d:>3}  {s} slot{d}  lv{d} *{d}", .{ it.uid, set, slot, it.level, it.star });
        const props = it.properties.items;
        if (props.len > 0) {
            try w.print("  main {s}", .{zzz.propName(props[0].key)});
            for (props[1..]) |p|
                try w.print("  {s}(+{d})", .{ zzz.propName(p.key), p.add_value -| 1 });
        }
        try w.writeByte('\n');
    }
    try w.writeByte('\n');

    // ── Equipped W-Engine + discs, per avatar ─────────────────────────────────
    const avatar_items = if (save.avatar) |av| av.items.items else &.{};
    var equipped_count: usize = 0;
    var bare_count: usize = 0;
    for (avatar_items) |a| {
        const slots = a.equipment_uids.items;
        const has_weapon = a.weapon_uid != 0;
        if (slots.len == 0 and !has_weapon) {
            bare_count += 1;
            continue;
        }
        equipped_count += 1;
        const name = zzz.avatarName(a.id) orelse "?";
        try w.print("avatar {d} ({s}):\n", .{ a.id, name });

        // W-Engine (`weapon_uid` stores raw uid + weapon_uid_base; 0 = none).
        try w.writeAll("  W-Engine: ");
        if (!has_weapon) {
            try w.writeAll("none\n");
        } else if (a.weapon_uid >= weapon_uid_base) {
            const raw = a.weapon_uid - weapon_uid_base;
            if (weapons_owned.get(raw)) |wid|
                try w.print("{d} ({s})\n", .{ raw, zzz.weaponName(wid) orelse "??" })
            else
                try w.print("{d} (dangling!)\n", .{raw});
        } else {
            // Not offset by base — malformed for an equipped weapon; show raw.
            try w.print("{d} (raw?)\n", .{a.weapon_uid});
        }

        // Discs (each slot stores raw uid + equipment_uid_base).
        try w.writeAll("  discs: ");
        if (slots.len == 0) {
            try w.writeAll("none");
        } else for (slots, 0..) |stored, i| {
            if (i != 0) try w.writeAll(", ");
            if (stored >= equipment_uid_base) {
                const raw = stored - equipment_uid_base;
                if (owned.contains(raw))
                    try w.print("{d}", .{raw})
                else
                    try w.print("{d}(dangling!)", .{raw});
            } else {
                // Not offset by base — malformed for an equipped slot; show raw.
                try w.print("{d}(raw?)", .{stored});
            }
        }
        try w.writeByte('\n');
    }
    try w.print("\n{d} avatar(s) with gear equipped; {d} with none.\n", .{ equipped_count, bare_count });

    try w.flush();
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
const zzz = @import("zzz_names.zig");

const Io = std.Io;
const Init = std.process.Init;
