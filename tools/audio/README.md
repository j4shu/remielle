# Audio restoration (voices + SFX) for CNBetaWin3.1.3

The beta client shipped with two kinds of audio stripping, both fixed by
serving live-3.0.0 files through a local CDN that the client's own login-time
"version correction" trusts:

1. **Voices**: the per-language `SoundBank_<L>_0.pck` were stripped of their
   embedded voice media (beta En: 6,596 banks but only 113 DIDX media
   payloads, 17 MB — live En: 16,564 payloads, 368 MB), and every
   `External_<L>_*.pck` / `Streamed_<L>_0.pck` was a 60-byte empty AKPK stub.
   Most ZZZ voice is in-memory Vorbis whose payload must live inside the
   SoundBank pck, so events fired into empty banks — total silence.
   Fix: serve live's SoundBank/External/Streamed pcks as-is.
2. **Combat SFX** (melee/skill/impact): the beta's `SoundBank_SFX_0..15.pck`
   contain only a **subset** of the SFX banks — 24,229 banks / 712 MB vs live
   3.0's 65,781 / 1.76 GB. The ~42k omitted banks hold nearly all combat
   audio (23,049 events, double what the beta kept). Combat events fire,
   `LoadBank` finds nothing in any registered package, and Wwise fails
   silently; UI banks made the subset, which is why UI sounds always worked.
   Fix: `merge-sfx-pck.py` rebuilds `SoundBank_SFX_11.pck` (the smallest) as
   all original beta banks byte-identical + every live bank whose ID exists
   in no beta SFX pck (+ the 6 streamed wems those banks reference). Bank IDs
   are name hashes, stable across versions, and Wwise resolves LoadBank
   against every registered package's LUT — so the added banks are found no
   matter which pck they sit in. Add-only: nothing that worked can regress.

## CDN mechanism

1. `dpsv/config.zon` → `game_res.base_url = "http://127.0.0.1:18888/"`, and its
   `audio_version` descriptor entry (fileSize + fileMD5) matches the forged
   manifest byte-for-byte. The manifest/descriptor "md5" fields are actually
   **xxHash64 (seed 0) of the file bytes, printed as decimal**.
2. A python `http.server` on :18888 (started by `tools/start-servers.ps1`)
   serves `<workspace>\audio-cdn\`. The client downloads the manifest from
   `base_url + "StandaloneWindows64/cn/audio_version"`, then any file whose
   manifest entry disagrees with its `Persistent\audio_version_persist`.
3. Downloads install into the client's `Persistent\`, which shadows
   StreamingAssets — so the served pcks replace the beta ones. External pcks
   are NOT persisted: the client re-streams them from the CDN on every
   voice-language switch, so **the CDN must run whenever the game does**.

## Files in this folder

- `merge-sfx-pck.py` — builds the merged `SoundBank_SFX_11.pck` straight onto
  the CDN (beta banks + live's omitted combat banks; prefers live Patch.pck
  versions of added banks since that's what live actually loads). Re-run
  whenever the live install's audio changes — see "When the live install
  updates" below.
- `update-cdn-soundbanks.ps1` — stages live SoundBank_{Cn,En,Jp}_0.pck and
  the beta Patch.pck stub onto the CDN, hashes the merged SFX pck in place,
  forges all their manifest entries (size + xxh64), and prints the new
  MANIFEST size/hash to paste into `dpsv/config.zon` (then rebuild — the
  config is comptime-embedded). Also refreshes the `audio_version` copy here.
- `audio_version` — the forged manifest the CDN currently serves (67,974 B,
  xxh64 14964258925784054074). Canonical copy lives on the CDN; the script
  keeps this one in sync.
- `audio_version_persist.orig` — the client's pristine beta
  `Persistent\audio_version_persist` (67,632 B), pre-forgery.
- `audio_version.orig` — hoyo's beta CDN manifest as originally downloaded
  (31,678 B). Kept for provenance/rollback only.
- `audio-analysis.py` / `audio-analysis2.py` — one-shot AKPK/`.bnk` parsers used
  to diagnose the stripped banks and measure live→beta coverage. Hardcoded
  machine-specific paths; kept because they encode the file formats (AKPK LUT
  offsets are in blockSize units; HIRC type 2/11 source extraction).

## Rebuilding `audio-cdn/` from scratch

The served pcks (~2.2 GB copies + hardlinks) are too big to version. To
recreate `<workspace>\audio-cdn\StandaloneWindows64\cn\`:

```powershell
$cdn = "<workspace>\audio-cdn\StandaloneWindows64\cn"
$beta = "<workspace>\CNBetaWin3.1.3\ZenlessZoneZeroBeta_Data\StreamingAssets\Audio\Windows\Full"
Copy-Item "<repo>\tools\audio\audio_version" $cdn   # forged manifest
foreach ($L in 'Cn','En','Jp') {                    # externals: hardlinks, no disk cost
  New-Item -ItemType Directory -Force "$cdn\Audio\Windows\Full\$L" | Out-Null
  foreach ($f in (Get-ChildItem "$beta\$L" -Filter 'External_*.pck') +
                 (Get-ChildItem "$beta\$L" -Filter 'Streamed_*.pck')) {
    New-Item -ItemType HardLink -Path "$cdn\Audio\Windows\Full\$L\$($f.Name)" -Target $f.FullName
  }
}
python "<repo>\tools\audio\merge-sfx-pck.py"        # merged SFX pck (~1.1 GB)
& "<repo>\tools\audio\update-cdn-soundbanks.ps1"    # stages the rest + re-forges
```

Then paste the printed MANIFEST size/hash into config.zon and rebuild. Note the
beta's StreamingAssets External/Streamed pcks must already hold the live
payloads (they were imported from the live install; the beta originals were
60 B stubs — pristine copies in `<workspace>\audio-import-backup\`).

## When the live install updates

All restored audio is sourced from the live install, so a live update (e.g.
3.0 → 3.1) is the main event to re-run against — and a 3.1+ live may recover
content that is currently silent (3.1-only banks/media), so it's worth
re-running for that alone:

1. `python "<repo>\tools\audio\merge-sfx-pck.py"` — re-diffs beta-vs-live bank
   IDs from scratch, so a newer live simply changes what gets merged.
2. `& "<repo>\tools\audio\update-cdn-soundbanks.ps1"` — re-stages the language
   SoundBanks + Patch stub, hashes the merged SFX pck, re-forges the manifest.
3. Paste the printed MANIFEST size/xxh64 into the `audio_version` entry of
   `dpsv/config.zon` (`game_res.md5_files`).
4. Rebuild/restart the servers (the config is comptime-embedded), then log in
   — version correction downloads the changed files.

If the live External/Streamed voice payloads changed too, first re-import them
into the beta's StreamingAssets and refresh the CDN hardlinks (see the
rebuild-from-scratch section above; pristine beta originals are in
`<workspace>\audio-import-backup\`).

Why this survives version bumps: bank/media IDs are name hashes, stable across
versions; Wwise resolves LoadBank against every registered package's LUT, so
placement doesn't matter; the merge is add-only, so nothing that works can
regress; and the hashes are xxh64-as-decimal at exactly two layers — the file
entries inside the manifest, and the manifest itself in config.zon.

## Warnings & limits

- **Don't revert the `game_res` block in config.zon**: hoyo's real beta CDN
  still serves its manifest but 404s every pck, stranding the client at
  "version correction" / "Download failed 200" (= descriptor/manifest hash
  mismatch).
- **Never write into the live install** (`C:\Games\HoYoPlay\...`) — it is a
  read-only source.
- **Don't serve live's real `Patch.pck`** (tried 2026-07, reverted): its 2,220
  live-3.0 HIRC banks — including a smaller 3.0 `Init.bnk` bus/state hierarchy
  — collide with and can shadow the beta's 3.1 banks by ID (the atimes show it
  registers before the SFX pcks), and its 915 media-only banks never load
  because the beta has no metadata for them. It stays at the beta's 60 B stub.
- Live 3.0 covers ~85% of the beta's voice media refs; 3.1-only content stays
  silent. Korean voice was never grafted.
- SFX that hoyo never distributed anywhere stays silent: 2,521 Event-only stub
  banks and ~340 beta-only bank IDs (likely 3.1-new content), plus ~300 media
  refs of the added banks that are absent from live too. Restored combat
  sounds are live-3.0 versions of the banks.
