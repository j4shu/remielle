# Combat sandbox — post-mortem (abandoned)

**Status: dead end, reverted 2026-07-03.** The goal was an in-game combat
sandbox on the beta client: spawn chosen enemies (Training-Camp-style waves) to
test builds and teams. It is not achievable server-side, and the fallback
(server picks which pre-authored fight loads) turned out to be ignored by the
client. All server changes were rolled back; this document is the only artifact
kept, so the discovery doesn't have to be repeated.

## Why it can't work

Two independent walls:

1. **The server never spawns enemies.** Fights in ZZZ are 100% client-simulated.
   When a training quest starts, the server sends a single
   `EnterSceneScNotify{ scene_type=3, play_type, scene_id, dungeon{ quest_id, dungeon_package_info } }`
   and the client does everything else (arena, enemies, waves, combat) from its
   own baked data. There is no protocol surface for authoring enemy composition
   server-side.
2. **The client doesn't even honor the server's _choice of fight_ for training
   scenes.** It plays whatever menu entry the player clicked; the notify's
   `scene_id` and `dungeon.quest_id` were both experimentally shown to be
   ignored for content selection (test matrix below). So the fallback idea —
   remap Free Training to an arbitrary battle event — is dead too.

The one remaining hope would be a client-side enemy-picker UI in Free Training
(live ZZZ has one; since fights are client-simulated it would work with zero
server involvement), but it was never found in the `CNBetaWin3.1.3` build — see
"Open leads".

## What was built (all reverted)

1. **Unlock-all training quests.** Upstream rejects every training quest except
   Free Training (12254000) and reports none as unlocked. Changes:
   `getQuestData` reported all ~108 `TrainingQuestTemplateTb` entries
   (quest_type 17) as finished/unlocked (`QuestInfo{ state=3, unlock_time=1 }`
   - the finished-id list), and `packAvatarInfo` stamped a nonzero
     `first_get_time` (agents with 0 read as trials, which keeps the
     "cooperation exercise" drills locked with _"Unlocked formally upon
     contracting the Agent"_). Result: **worked** — every entry unlocked and
     loaded when clicked directly.
2. **Trial-avatar acceptance in `startTrainingQuest`.** Drills/camps send
   9-digit quest-prefixed _trial_ avatar ids (e.g. `122541011`, `122541081` for
   quest 12254001) instead of real agent ids (`1091`, `1511`, …). Validating
   them as real agents rejected the start, which the client experiences as an
   infinite black screen (see the dummy-ack gotcha below). Accepting them (empty
   lineup slots server-side; the client owns trial stats/gear entirely) made all
   entries load. Result: **worked**.
3. **Any-fight remap.** A runtime file `Persistent/sandbox.zon`, re-read on
   every training start, remapped a clicked quest to an arbitrary
   `battle_event_id`/`play_type` in the notify (and swapped `dungeon.quest_id`
   when the target was itself a training event, since the working theory was the
   client keyed fights off its quest table). Mechanically the server side was
   verified via logs — the swapped notify went out — but the client ignored it.
   Result: **dead end**.

## Test matrix (the decisive evidence)

All with `scene_type=3`, `play_type=290`, on client `CNBetaWin3.1.3`:

| notify sent (after remap)                                           | client behavior                                  |
| ------------------------------------------------------------------- | ------------------------------------------------ |
| quest 12254000 (Free Training) + `scene_id` 70200005 (camp fight)   | plain Free Training — `scene_id` ignored         |
| quest 12255001 (camp) + `scene_id` 70200005, real-avatar package    | infinite black screen                            |
| quest 12254001 (drill) + `scene_id` 19800015, real-avatar package   | plain Free Training — `dungeon.quest_id` ignored |
| direct clicks on any of the ~108 entries (notify matches the click) | all load correctly                               |

Conclusion: for training scenes, fight content is selected client-side from the
clicked menu entry. The camp black screen is a flow/consistency failure on a
mismatched notify, not missing stage data (camp stages load fine when clicked
directly) — though whether the trigger was the mismatched quest id or the
real-avatar lineup package was never isolated (see "Open leads").

## Protocol findings worth keeping

- **Dummy-ack blindspot:** `StartTrainingQuestScRsp` has no descriptor in the
  protocol dump, so the server can only send a bare ack — a rejection's retcode
  physically never reaches the client, which then waits forever for the scene
  notify. In game, _any_ server-side rejection of a training start is an
  infinite black screen. Be maximally permissive in that handler.
- **Trial avatar ids** are `<quest_id><slot>`-shaped 9-digit values (`122541011`
  = quest 12254001). They must never be looked up in the player's roster:
  `packDungeonPackageInfo` asserts (`.?`) on unknown ids.
- **Menu unlock levers:** the client polls `GetQuestData` once at login with
  `quest_type=0` ("all"); returning the quest_type-17 collection with finished
  ids + `state=3` unlocks the training menu, and nonzero `first_get_time` on
  avatars clears the agent-gated drill locks. (State value 3 was a guess that
  worked; the `QuestState` enum semantics were never confirmed.)
- **Recovery from a black screen:** pause menu → leave, or relog.

## Open leads (if ever resumed)

- `StartTrainingQuestCsReq` carries four obfuscated fields (`BOFCPNOIJKK`,
  `ILFHMEJNHHK`, `CMEOEMIIADI`, `KKMKIFHAJGM`) that were **empty in every
  capture**. If the beta's Free Training does have a hidden enemy-picker UI, its
  selection plausibly rides in these — capture the request dump if a picker is
  ever found.
- cmd_id 4163 (obfuscated `CKMHGDAOLBF`, has an `avatar_list` field) is sent by
  the client right after every training start; never handled, and loading works
  without it.
- Never run: remapping a _drill_ → camp event (drills send trial ids → empty
  lineup package → the notify is byte-identical to a working direct camp click),
  which would isolate whether the camp black screen was the package or the
  client's own click state. Also untried: `play_type` values other than 290.
- **Hadal Zone** is the other combat mode remielle implements server-side — real
  boss fights with the player's own teams; the practical alternative for build
  testing.

## Revert inventory

Rolled back (uncommitted working-tree changes on `feature/tools`):
`gamesv/src/Server.zig`, `gamesv/src/app.zig`, `gamesv/src/logic.zig`,
`gamesv/src/logic/Changes.zig`, `gamesv/src/logic/Sandbox.zig` (new file,
deleted), `gamesv/src/messaging/handlers.zig`,
`gamesv/src/messaging/handlers/quest.zig`,
`gamesv/src/messaging/notifiers/scene.zig`, `gamesv/src/messaging/packers.zig`,
`gamesv/src/Assets/templates/training_quest.zig`, plus the runtime file
`Persistent/sandbox.zon` and the sample `tools/sandbox/sandbox.sample.zon`.
Post-revert behavior is upstream's: only Free Training is playable; other
training entries are locked in the menu and would black-screen if started.
