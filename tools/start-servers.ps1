# start-servers.ps1
# Launches the ZZZ emulator backends via remielle's `zig build serve-all`:
#   sdksv  (auth / login / SDK) -> http://127.0.0.1:20100
#   dpsv   (dispatch)           -> http://127.0.0.1:12401
#   gamesv (game)               -> 127.0.0.1:20501 (UDP)
#
# The servers run in their own window so you can read the logs.
#
# There is no registration web page. sdksv creates
# your account automatically the first time you log in from the game's login
# screen -- just enter any username + password. The client must be patched
# with "vortex" (supported client version: CNBetaWin3.1.3).
#
# Lives in remielle/tools so it's versioned; the workspace root has a shim
# that calls it. Expects the workspace layout: remielle/ and audio-cdn/ as
# siblings under the workspace root.

$remiDir = Resolve-Path (Join-Path $PSScriptRoot '..')
$root = Split-Path $remiDir

# remielle — source envrc.ps1 first so the correct Zig 0.16.0 (in .direnv) is on
# PATH regardless of any other zig on the system, then build + serve all three
# servers at once (dpsv + sdksv + gamesv).
Start-Process -FilePath 'powershell' `
  -ArgumentList '-NoExit', '-Command', '. .\envrc.ps1; zig build serve-all' `
  -WorkingDirectory $remiDir

# audio-cdn — local stand-in for the (defunct) hoyo autopatch CDN. dpsv's
# game_res.base_url points here; the client fetches audio_version and the real
# voice .pck files (live SoundBanks + hardlinks into the beta's
# StreamingAssets) during its login-time version correction, and re-streams
# External pcks on every voice-language switch. Without it the correction gets
# stuck. See tools/audio/README.md.
$cdnDir = Join-Path $root 'audio-cdn'
if ((Test-Path $cdnDir) -and -not (Get-NetTCPConnection -State Listen -LocalPort 18888 -ErrorAction SilentlyContinue)) {
  Start-Process -FilePath 'python' `
    -ArgumentList '-m', 'http.server', '18888', '--bind', '127.0.0.1' `
    -WorkingDirectory $cdnDir -WindowStyle Minimized
}

Write-Host ''
Write-Host 'Backends starting in a separate window:' -ForegroundColor Cyan
Write-Host '  sdksv  -> http://127.0.0.1:20100'
Write-Host '  DPSV   -> http://127.0.0.1:12401'
Write-Host '  GAMESV -> 127.0.0.1:20501 (UDP)'
Write-Host '  audio  -> http://127.0.0.1:18888 (local CDN for voice files)'
Write-Host ''
Write-Host 'Launch the game by running velina.exe in the client folder.'
