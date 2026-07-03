"""Cross-reference beta SoundBank voice references vs live pck contents."""
import struct, sys, os

def parse_akpk(path):
    """Return dict with language map, banks/stm/externals LUTs."""
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:4] == b'AKPK', f'{path}: not AKPK'
    hdr_len, version, lang_sz, banks_sz, stm_sz, ext_sz = struct.unpack_from('<6I', data, 4)
    pos = 28
    # language map
    lang_start = pos
    (nlang,) = struct.unpack_from('<I', data, pos)
    langs = {}
    entries = []
    for i in range(nlang):
        off, lid = struct.unpack_from('<II', data, lang_start + 4 + i * 8)
        entries.append((off, lid))
    for off, lid in entries:
        s = lang_start + off
        chars = []
        while data[s:s+2] != b'\x00\x00':
            chars.append(data[s:s+2].decode('utf-16-le'))
            s += 2
        langs[lid] = ''.join(chars)
    pos = lang_start + lang_sz

    def lut32(pos):
        (n,) = struct.unpack_from('<I', data, pos)
        out = []
        for i in range(n):
            fid, blk, size, off, lid = struct.unpack_from('<5I', data, pos + 4 + i * 20)
            out.append((fid, size, off * blk, lid))  # offset is in blockSize units
        return out

    banks = lut32(pos); pos += banks_sz
    stm = lut32(pos); pos += stm_sz
    (n_ext,) = struct.unpack_from('<I', data, pos)
    ext = []
    for i in range(n_ext):
        fid, blk, size, off, lid = struct.unpack_from('<QIIII', data, pos + 4 + i * 24)
        ext.append((fid, size, off * blk, lid))
    return {'langs': langs, 'banks': banks, 'stm': stm, 'ext': ext, 'data': data}

def parse_bnk_sources(bnk):
    """Extract (sourceID, streamType) from HIRC Sound + MusicTrack objects; also DIDX ids."""
    pos = 0
    sources = []
    didx = set()
    bank_version = None
    while pos + 8 <= len(bnk):
        tag = bnk[pos:pos+4]; (size,) = struct.unpack_from('<I', bnk, pos+4)
        body = pos + 8
        if tag == b'BKHD':
            bank_version = struct.unpack_from('<I', bnk, body)[0]
        elif tag == b'DIDX':
            for i in range(size // 12):
                (mid,) = struct.unpack_from('<I', bnk, body + i * 12)
                didx.add(mid)
        elif tag == b'HIRC':
            (count,) = struct.unpack_from('<I', bnk, body)
            p = body + 4
            for _ in range(count):
                htype = bnk[p]; (hsize,) = struct.unpack_from('<I', bnk, p+1)
                hbody = p + 5
                if htype == 2:  # Sound: ulID, then AkBankSourceData
                    plugin_id, = struct.unpack_from('<I', bnk, hbody + 4)
                    stream_type = bnk[hbody + 8]
                    src_id, = struct.unpack_from('<I', bnk, hbody + 9)
                    sources.append((src_id, stream_type, plugin_id))
                elif htype == 11:  # MusicTrack: ulID, uFlags(u8), numSources(u32), sources...
                    p2 = hbody + 4 + 1
                    (nsrc,) = struct.unpack_from('<I', bnk, p2)
                    p2 += 4
                    for _ in range(nsrc):
                        plugin_id, = struct.unpack_from('<I', bnk, p2)
                        stream_type = bnk[p2 + 4]
                        src_id, = struct.unpack_from('<I', bnk, p2 + 5)
                        sources.append((src_id, stream_type, plugin_id))
                        p2 += 14  # pluginID(4)+streamType(1)+sourceID(4)+inMemSize(4)+sourceBits(1)
                p += 5 + hsize
        pos = body + size
    return bank_version, sources, didx

def analyze_soundbank_pck(path, label):
    pk = parse_akpk(path)
    print(f'--- {label} ({os.path.getsize(path):,} B) ---')
    print(f'  langs={pk["langs"]}, banks={len(pk["banks"])}, stm={len(pk["stm"])}, ext={len(pk["ext"])}')
    all_sources = []
    all_didx = set()
    versions = {}
    no_bkhd = 0
    first_probe = True
    for fid, size, off, lid in pk['banks']:
        blob = pk['data'][off:off+size]
        if first_probe:
            print(f'  first bank id={fid} @{off}: head={blob[:16].hex(" ")}')
            first_probe = False
        ver, src, didx = parse_bnk_sources(blob)
        if ver is None:
            no_bkhd += 1
        else:
            versions[ver] = versions.get(ver, 0) + 1
        all_sources.extend(src)
        all_didx |= didx
    print(f'  bnk versions={versions}, banks w/o BKHD={no_bkhd}, total hirc sources={len(all_sources)}, didx media={len(all_didx)}')
    return pk, all_sources, all_didx

beta = r'C:\Users\jshu\Desktop\ZZZ\audio-import-backup\beta-originals\En\SoundBank_En_0.pck'
live_sb = r'C:\Games\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero_Data\StreamingAssets\Audio\Windows\Full\En\SoundBank_En_0.pck'
live_stm = r'C:\Games\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero_Data\StreamingAssets\Audio\Windows\Full\En\Streamed_En_0.pck'
live_ext0 = r'C:\Games\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero_Data\StreamingAssets\Audio\Windows\Full\En\External_En_0.pck'
beta_num = r'C:\Users\jshu\Desktop\ZZZ\CNBetaWin3.1.3\ZenlessZoneZeroBeta_Data\StreamingAssets\Audio\Windows\Full\En\10100.pck'

bpk, bsrc, bdidx = analyze_soundbank_pck(beta, 'BETA SoundBank_En_0.pck')
lpk, lsrc, ldidx = analyze_soundbank_pck(live_sb, 'LIVE SoundBank_En_0.pck')

stm_pk = parse_akpk(live_stm)
print(f'--- LIVE Streamed_En_0.pck: langs={stm_pk["langs"]}, stm entries={len(stm_pk["stm"])}, ext={len(stm_pk["ext"])}')
ext_pk = parse_akpk(live_ext0)
print(f'--- LIVE External_En_0.pck: langs={ext_pk["langs"]}, stm={len(ext_pk["stm"])}, ext entries={len(ext_pk["ext"])}')
num_pk = parse_akpk(beta_num)
print(f'--- BETA 10100.pck: langs={num_pk["langs"]}, banks={len(num_pk["banks"])}, stm={len(num_pk["stm"])}, ext entries={len(num_pk["ext"])}')

live_stm_ids = {fid for fid, *_ in stm_pk['stm']}

beta_streamed = {sid for sid, st, pid in bsrc if st == 2}
beta_inmem = {sid for sid, st, pid in bsrc if st == 0}
print()
print(f'BETA bank: {len(bsrc)} sources total; streamed={len(beta_streamed)}, in-memory={len(beta_inmem)} (didx={len(bdidx)})')
hits = beta_streamed & live_stm_ids
print(f'  beta streamed refs found in LIVE Streamed_En_0: {len(hits)}/{len(beta_streamed)}')

live_streamed = {sid for sid, st, pid in lsrc if st == 2}
lhits = live_streamed & live_stm_ids
print(f'LIVE bank sanity: {len(lsrc)} sources; streamed={len(live_streamed)}, self-hits={len(lhits)}/{len(live_streamed)}')

# plugin id histogram for beta sources (spot external-source plugin usage)
from collections import Counter
pc = Counter(f'{pid:#010x}' for _, _, pid in bsrc)
print(f'BETA plugin ids: {dict(pc.most_common(6))}')
st_hist = Counter(st for _, st, _ in bsrc)
print(f'BETA stream types: {dict(st_hist)}')
lpc = Counter(f'{pid:#010x}' for _, _, pid in lsrc)
print(f'LIVE plugin ids: {dict(lpc.most_common(6))}')
lst_hist = Counter(st for _, st, _ in lsrc)
print(f'LIVE stream types: {dict(lst_hist)}')

# how many of the beta's streamed refs exist in live External pcks (u64 LUT, compare vs u32 set)?
live_ext_ids = set()
for i in range(16):
    p = live_ext0.replace('External_En_0', f'External_En_{i}')
    if os.path.exists(p):
        live_ext_ids |= {fid for fid, *_ in parse_akpk(p)['ext']}
        live_ext_ids |= {fid for fid, *_ in parse_akpk(p)['stm']}
print(f'LIVE all External_En_*: {len(live_ext_ids)} ids')
hits_ext = {sid for sid in beta_streamed if sid in live_ext_ids}
print(f'  beta streamed refs found in LIVE External_En_*: {len(hits_ext)}/{len(beta_streamed)}')
