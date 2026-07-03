# Character builds (W-Engines + drive discs) for remielle saves

A declarative loadout pipeline for the `PlayerSave` `.bin` files under
`Persistent/LocalStorage/`. You describe each character's gear once in `builds.zon` —
one W-Engine plus six drive discs — and `edit-save` turns that spec into reality:
it validates the whole file at compile time (a bad spec fails **before** the save is
even read), backs the save up to `.bak`, replaces the weapon/disc inventories, and
auto-equips everything onto the right characters. No manual equipping in game.

## Files in this folder

- `builds.zon` — the spec, one block per character. Imported at comptime by
  `edit-save` (as the anonymous module `"builds"` wired in `../../build.zig`). Its
  top doc comment is the authoritative, always-current rule list.
- `edit-save.zig` — the writer (`zig build edit-save`). Also comptime-imports
  `assets/filecfg/EquipmentSuitTemplateTb.zon` + `WeaponTemplateTb.zon` to reject
  unknown set/weapon ids, and holds the authoritative `Stat` enum.
- `inspect-save.zig` — read-only companion (`zig build inspect-save`); dumps a save's
  W-Engines, discs, and per-avatar equipped slots. Never writes.
- `zzz_names.zig` — shared friendly-name tables (`Set`, `Stat`, `Avatar`, `Weapon`,
  `propName`), imported by both tools.
- `gen_names.py` — regenerates the `Avatar`/`Weapon` enum bodies in `zzz_names.zig`
  from EnkaNetwork data (see below).

## Usage (from `remielle/`, after `. .\envrc.ps1`)

```
zig build edit-save -- Persistent/LocalStorage/USD_666.bin
```

**Only while logged out / servers stopped.** Backs up to `<save>.bak` first, then
REPLACES the entire weapon + disc inventories with exactly what `builds.zon` lists —
a character without a block ends up with no weapon and empty disc slots. Re-running
is idempotent. A listed character not owned in the save is reported and skipped
(its items still land in the inventory).

```
zig build inspect-save -- Persistent/LocalStorage/USD_666.bin
```

Read-only, safe any time — use it to verify what the save actually contains.

## The spec (`builds.zon`)

The root is `.characters`: a list of per-character blocks, each with an `.avatar`,
a `.weapon` (one maxed lv60/\*5/R5 copy is created and equipped), and exactly six
`.slots`. Convention: the 4-PC set on slots 3-6, the 2-PC off-set on slots 1-2
(bonuses are slot-independent; the split is bookkeeping). Slots 1/2/3 get automatic
mains (HpFlat/AtkFlat/DefFlat); slots 4/5/6 declare `.main`. Every slot lists exactly
4 substats whose upgrade counts sum to 5.

All of this is enforced as `@compileError`s — unknown set/weapon, illegal main for
a slot, sub colliding with the main, duplicate subs, wrong sub count or weights.
`builds.zon`'s own doc comment is the full rule list and stays in sync with
`edit-save.zig`.

## Name tables & the generator

`Set` and `Stat` in `zzz_names.zig` are hand-maintained and complete. The `Avatar`
and `Weapon` enum bodies between the `// <gen:…>` markers are generated — regenerate,
don't hand-edit inside the markers:

```
python tools/builds/gen_names.py           # fetch EnkaNetwork data, rewrite zzz_names.zig
python tools/builds/gen_names.py --check   # dry-run; exit 1 if it would change
python tools/builds/gen_names.py --dir D   # read the three JSON files locally
```

Entries are inert until `builds.zon` references them, so pre-population is safe.

New drive-disc set (two steps, in order): first update
`assets/filecfg/EquipmentSuitTemplateTb.zon` from a game dump that has the set (diff
against the old copy to find the new id + 2pc bonus), then add one `Set` enum line —
or a numeric placeholder `Set<id> = <id>,` when EnkaNetwork doesn't have the name yet
(rename later; see the existing `Set34100`/`Set34200`). Referencing a set before both
steps is a loud `@compileError` at apply time.

## Adding a build

The workspace `add-build` skill (`.claude/skills/add-build/`, outside this repo)
derives a block from a prydwen.gg character URL and writes it into `builds.zon`;
applying is always a manual `zig build edit-save`, never the skill's.
