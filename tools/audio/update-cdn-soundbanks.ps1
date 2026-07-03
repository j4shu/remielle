# Stage live audio pcks on the local audio CDN and re-forge the manifest.
#
# Re-run whenever the live install's audio changes (or when rebuilding the
# audio-cdn folder from scratch -- see README.md). Afterwards, copy the printed
# MANIFEST size/hash into the `audio_version` entry of dpsv/config.zon
# (`game_res.md5_files`) and rebuild the servers: the config is
# comptime-embedded, so the running dpsv won't pick it up otherwise.
param(
  # The retail install's _Data folder. Read-only source; never written to.
  [string]$LiveData = 'C:\Games\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero_Data',
  [string[]]$Langs = @('En', 'Jp', 'Cn')
)
$ErrorActionPreference = 'Stop'

# tools\audio -> tools -> remielle -> workspace root
$wsRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$cdn = Join-Path $wsRoot 'audio-cdn\StandaloneWindows64\cn'
if (-not (Test-Path $cdn)) { throw "audio-cdn not found at $cdn" }

if (-not ('XX6' -as [type])) {
Add-Type -TypeDefinition @'
using System;
public static class XX6 {
  const ulong P1=11400714785074694791UL,P2=14029467366897019727UL,P3=1609587929392839161UL,P4=9650029242287828579UL,P5=2870177450012600261UL;
  static ulong Rot(ulong x,int r){return (x<<r)|(x>>(64-r));}
  public static ulong H64(byte[] d, ulong seed){
    int len=d.Length; int i=0; ulong h;
    if(len>=32){ ulong v1=seed+P1+P2, v2=seed+P2, v3=seed, v4=seed-P1;
      while(i+32<=len){ v1=Rot(v1+BitConverter.ToUInt64(d,i)*P2,31)*P1; i+=8; v2=Rot(v2+BitConverter.ToUInt64(d,i)*P2,31)*P1; i+=8; v3=Rot(v3+BitConverter.ToUInt64(d,i)*P2,31)*P1; i+=8; v4=Rot(v4+BitConverter.ToUInt64(d,i)*P2,31)*P1; i+=8; }
      h=Rot(v1,1)+Rot(v2,7)+Rot(v3,12)+Rot(v4,18);
      h=(h^(Rot(v1*P2,31)*P1))*P1+P4; h=(h^(Rot(v2*P2,31)*P1))*P1+P4; h=(h^(Rot(v3*P2,31)*P1))*P1+P4; h=(h^(Rot(v4*P2,31)*P1))*P1+P4;
    } else h=seed+P5;
    h+=(ulong)len;
    while(i+8<=len){ h^=Rot(BitConverter.ToUInt64(d,i)*P2,31)*P1; h=Rot(h,27)*P1+P4; i+=8; }
    if(i+4<=len){ h^=(ulong)BitConverter.ToUInt32(d,i)*P1; h=Rot(h,23)*P2+P3; i+=4; }
    while(i<len){ h^=d[i]*P5; h=Rot(h,11)*P1; i++; }
    h^=h>>33; h*=P2; h^=h>>29; h*=P3; h^=h>>32; return h; } }
'@
}

# Files staged from the live install, with candidate sources in preference
# order. Live keeps its default-language SoundBank in StreamingAssets and the
# rest in the Persistent overlay.
$staged = @()
foreach ($lang in $Langs) {
  $staged += @{
    remote  = 'Audio/Windows/Full/{0}/SoundBank_{0}_0.pck' -f $lang
    sources = @("$LiveData\StreamingAssets\Audio\Windows\Full\$lang\SoundBank_${lang}_0.pck",
                "$LiveData\Persistent\Audio\Windows\Full\$lang\SoundBank_${lang}_0.pck")
  }
}
# Runtime audio patch: kept at the beta's own 60 B stub. Serving live's real
# Patch.pck was tried and reverted: its 2,220 live-3.0 HIRC banks (including a
# smaller 3.0 Init.bnk bus hierarchy) shadow the beta's 3.1 banks by ID, and
# its media-only banks never load anyway (the beta has no metadata for them).
$staged += @{
  remote  = 'Audio/Windows/Full/Patch.pck'
  sources = @("$wsRoot\CNBetaWin3.1.3\ZenlessZoneZeroBeta_Data\StreamingAssets\Audio\Windows\Full\Patch.pck")
}
# Merged SFX pck built by merge-sfx-pck.py (beta banks + live's ~42k omitted
# combat banks). Already written to the CDN by that tool; hash it in place.
$staged += @{
  remote = 'Audio/Windows/Full/SoundBank_SFX_11.pck'
}

$manifest = Join-Path $cdn 'audio_version'
Copy-Item $manifest ($manifest + '.bak') -Force
$json = [IO.File]::ReadAllText($manifest)

foreach ($f in $staged) {
  $dst = Join-Path $cdn ($f.remote -replace '/', '\')
  if ($f.ContainsKey('sources')) {
    $src = $f.sources | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $src) { throw "no source for $($f.remote)" }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
    (Get-Item $dst).IsReadOnly = $false   # live Persistent files carry a read-only attribute
  } elseif (-not (Test-Path $dst)) {
    throw "$($f.remote) not staged at $dst (run its build tool first)"
  }
  $bytes = [IO.File]::ReadAllBytes($dst)
  $hash = [XX6]::H64($bytes, 0)
  $re = '("remoteName":\s*"' + [regex]::Escape($f.remote) + '",\s*"md5":\s*")\d+(",\s*"fileSize":\s*)\d+'
  $m = [regex]::Matches($json, $re)
  if ($m.Count -ne 1) { throw "manifest entry match count $($m.Count) for $($f.remote)" }
  $json = [regex]::Replace($json, $re, ('${1}' + $hash + '${2}' + $bytes.Length))
  Write-Output ("{0}: size={1} xxh64={2}" -f $f.remote, $bytes.Length, $hash)
}

[IO.File]::WriteAllText($manifest, $json, (New-Object System.Text.UTF8Encoding($false)))
# Keep the versioned copy next to this script in sync with what the CDN serves.
Copy-Item $manifest (Join-Path $PSScriptRoot 'audio_version') -Force
$mb = [IO.File]::ReadAllBytes($manifest)
$mh = [XX6]::H64($mb, 0)
Write-Output ("MANIFEST: size={0} xxh64={1} -> paste into dpsv/config.zon game_res audio_version entry" -f $mb.Length, $mh)
