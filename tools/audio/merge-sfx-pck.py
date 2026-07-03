"""Merge live-3.0 SFX banks that the beta distribution omitted into one beta pck.

Why: the CNBetaWin3.1.3 distribution ships only a subset of the SFX soundbanks
(24,229 banks / 712 MB vs live 3.0's 65,781 / 1.76 GB). The ~42k omitted banks
hold nearly all combat audio (melee/skill/impact) — combat events fire, the
bank isn't in any registered package, and the result is silence with no error.
UI banks made the subset, which is why UI sounds still work.

Fix shape: rebuild SoundBank_SFX_11.pck (the smallest beta SFX pck) as
    [all original beta SFX_11 banks, byte-identical] + [every live bank whose
    ID exists in no beta SFX pck]
plus a streamed-LUT section carrying the handful of streamed wems the added
banks need. Bank IDs are name hashes, stable across versions, and Wwise
resolves a LoadBank against every registered package's LUT — so the added
banks are found no matter which pck they sit in. Add-only: no beta bank is
modified, so nothing that works today can regress. Where live's runtime patch
(Patch.pck) carries a newer version of an added bank, the patch version is
preferred (that is what live actually loads).

Output goes straight to the local audio CDN; serve it by re-forging the
manifest (update-cdn-soundbanks.ps1) and bumping dpsv/config.zon.

Known limits: beta-3.1-only events whose banks hoyo never distributed stay
silent (the 2,521 Event-only stub banks and 343 beta-only IDs are kept as-is);
~300 media refs of the added banks are absent from live too and stay silent
there as well.
"""
import argparse
import glob
import os
import struct
import sys
import tempfile

BLOCK = 16

def parse_akpk(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'AKPK':
        raise ValueError(f'{path}: not AKPK')
    hdr_len, version, lang_sz, banks_sz, stm_sz, ext_sz = struct.unpack_from('<6I', data, 4)
    pos = 28
    langmap = data[pos:pos + lang_sz]
    pos += lang_sz

    def lut(pos):
        (n,) = struct.unpack_from('<I', data, pos)
        return [struct.unpack_from('<5I', data, pos + 4 + i * 20) for i in range(n)]

    banks = [(fid, size, off * blk, lid) for fid, blk, size, off, lid in lut(pos)]
    pos += banks_sz
    stm = [(fid, size, off * blk, lid) for fid, blk, size, off, lid in lut(pos)]
    return {'langmap': langmap, 'banks': banks, 'stm': stm, 'data': data}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--beta', default=r'C:\Users\jshu\Desktop\ZZZ\CNBetaWin3.1.3'
                    r'\ZenlessZoneZeroBeta_Data\StreamingAssets\Audio\Windows\Full')
    ap.add_argument('--live', default=r'C:\Games\HoYoPlay\games\ZenlessZoneZero Game'
                    r'\ZenlessZoneZero_Data')
    ap.add_argument('--out', default=r'C:\Users\jshu\Desktop\ZZZ\audio-cdn'
                    r'\StandaloneWindows64\cn\Audio\Windows\Full\SoundBank_SFX_11.pck')
    args = ap.parse_args()

    live_sa = os.path.join(args.live, r'StreamingAssets\Audio\Windows\Full')
    live_patch = os.path.join(args.live, r'Persistent\Audio\Windows\Full\Patch.pck')

    # every bank ID the beta already has, across all 16 SFX pcks
    beta_ids = set()
    for p in sorted(glob.glob(os.path.join(args.beta, 'SoundBank_SFX_*.pck'))):
        beta_ids |= {fid for fid, *_ in parse_akpk(p)['banks']}
    print(f'beta SFX bank ids: {len(beta_ids)}')

    base = parse_akpk(os.path.join(args.beta, 'SoundBank_SFX_11.pck'))
    print(f'merge base SoundBank_SFX_11.pck: {len(base["banks"])} banks')

    # which IDs are we adding, and which streamed wems do they need
    live_ids = set()
    for p in sorted(glob.glob(os.path.join(live_sa, 'SoundBank_SFX_*.pck'))):
        live_ids |= {fid for fid, *_ in parse_akpk(p)['banks']}
    missing = live_ids - beta_ids
    print(f'live SFX bank ids: {len(live_ids)}; missing from beta: {len(missing)}')

    beta_stm_ids = set()
    for p in sorted(glob.glob(os.path.join(args.beta, 'Streamed_SFX_*.pck'))):
        beta_stm_ids |= {fid for fid, *_ in parse_akpk(p)['stm']}

    def streamed_refs(bnk):
        pos, out = 0, set()
        while pos + 8 <= len(bnk):
            tag = bnk[pos:pos + 4]
            (size,) = struct.unpack_from('<I', bnk, pos + 4)
            body = pos + 8
            if tag == b'HIRC':
                (count,) = struct.unpack_from('<I', bnk, body)
                p = body + 4
                for _ in range(count):
                    htype = bnk[p]
                    (hsize,) = struct.unpack_from('<I', bnk, p + 1)
                    hbody = p + 5
                    if htype == 2:  # Sound
                        if bnk[hbody + 8] == 2:
                            out.add(struct.unpack_from('<I', bnk, hbody + 9)[0])
                    elif htype == 11:  # MusicTrack
                        p2 = hbody + 5
                        (nsrc,) = struct.unpack_from('<I', bnk, p2)
                        p2 += 4
                        for _ in range(nsrc):
                            if bnk[p2 + 4] == 2:
                                out.add(struct.unpack_from('<I', bnk, p2 + 5)[0])
                            p2 += 14
                    p += 5 + hsize
            pos = body + size
        return out

    # collect blobs into a temp data file, 16-aligned; LUT gets relative offsets
    tmp = tempfile.NamedTemporaryFile(delete=False, dir=os.path.dirname(args.out))
    entries = []      # (fid, size, rel_off, lid) for banks
    seen = set()
    stm_needed = set()

    def append(blob):
        rel = tmp.tell()
        assert rel % BLOCK == 0
        tmp.write(blob)
        if len(blob) % BLOCK:
            tmp.write(b'\x00' * (BLOCK - len(blob) % BLOCK))
        return rel

    try:
        # 1) beta SFX_11 banks, byte-identical
        for fid, size, off, lid in base['banks']:
            entries.append((fid, size, append(base['data'][off:off + size]), lid))
            seen.add(fid)

        # 2) patch-preferred versions of missing banks
        added = 0
        pp = parse_akpk(live_patch) if os.path.exists(live_patch) else None
        if pp:
            for fid, size, off, lid in pp['banks']:
                if fid in missing and fid not in seen:
                    blob = pp['data'][off:off + size]
                    entries.append((fid, size, append(blob), lid))
                    seen.add(fid)
                    stm_needed |= streamed_refs(blob)
                    added += 1
            print(f'added from live Patch.pck: {added}')
            del pp

        # 3) the rest from live base SFX pcks
        for p in sorted(glob.glob(os.path.join(live_sa, 'SoundBank_SFX_*.pck'))):
            pk = parse_akpk(p)
            n = 0
            for fid, size, off, lid in pk['banks']:
                if fid in missing and fid not in seen:
                    blob = pk['data'][off:off + size]
                    entries.append((fid, size, append(blob), lid))
                    seen.add(fid)
                    stm_needed |= streamed_refs(blob)
                    n += 1
            print(f'added from {os.path.basename(p)}: {n}')
            del pk

        # 4) streamed wems the added banks reference and the beta lacks
        stm_needed -= beta_stm_ids
        stm_entries = []
        if stm_needed:
            for p in sorted(glob.glob(os.path.join(live_sa, 'Streamed_SFX_*.pck'))):
                pk = parse_akpk(p)
                for fid, size, off, lid in pk['stm']:
                    if fid in stm_needed:
                        stm_entries.append((fid, size, append(pk['data'][off:off + size]), lid))
                        stm_needed.discard(fid)
                del pk
        print(f'streamed wems carried: {len(stm_entries)}; unresolved: {len(stm_needed)}')

        # ---- assemble ----------------------------------------------------
        entries.sort(key=lambda e: (e[0], e[3]))
        stm_entries.sort(key=lambda e: (e[0], e[3]))
        langmap = base['langmap']
        banks_sz = 4 + len(entries) * 20
        stm_sz = 4 + len(stm_entries) * 20
        ext_sz = 4
        hdr_len = 20 + len(langmap) + banks_sz + stm_sz + ext_sz
        data_start = 8 + hdr_len
        if data_start % BLOCK:
            data_start += BLOCK - data_start % BLOCK

        def lut_bytes(rows):
            out = [struct.pack('<I', len(rows))]
            for fid, size, rel, lid in rows:
                byte_off = data_start + rel
                assert byte_off % BLOCK == 0
                out.append(struct.pack('<5I', fid, BLOCK, size, byte_off // BLOCK, lid))
            return b''.join(out)

        tmp.close()
        with open(args.out, 'wb') as out:
            out.write(b'AKPK')
            out.write(struct.pack('<5I', hdr_len, 1, len(langmap), banks_sz, stm_sz))
            out.write(struct.pack('<I', ext_sz))
            out.write(langmap)
            out.write(lut_bytes(entries))
            out.write(lut_bytes(stm_entries))
            out.write(struct.pack('<I', 0))
            out.write(b'\x00' * (data_start - out.tell()))
            with open(tmp.name, 'rb') as t:
                while True:
                    chunk = t.read(1 << 24)
                    if not chunk:
                        break
                    out.write(chunk)
    finally:
        os.unlink(tmp.name)

    print(f'wrote {args.out}: {os.path.getsize(args.out):,} B, '
          f'{len(entries)} banks ({len(entries) - len(base["banks"])} added), '
          f'{len(stm_entries)} streamed')


if __name__ == '__main__':
    sys.exit(main())
