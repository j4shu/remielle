"""Step 2: coverage analysis — can live SoundBank pcks satisfy the beta's requests?"""
import struct, os, glob

def parse_akpk(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:4] == b'AKPK', f'{path}: not AKPK'
    hdr_len, version, lang_sz, banks_sz, stm_sz, ext_sz = struct.unpack_from('<6I', data, 4)
    pos = 28
    lang_start = pos
    pos = lang_start + lang_sz

    def lut32(pos):
        (n,) = struct.unpack_from('<I', data, pos)
        out = []
        for i in range(n):
            fid, blk, size, off, lid = struct.unpack_from('<5I', data, pos + 4 + i * 20)
            out.append((fid, size, off * blk, lid))
        return out

    banks = lut32(pos); pos += banks_sz
    stm = lut32(pos); pos += stm_sz
    (n_ext,) = struct.unpack_from('<I', data, pos)
    ext = []
    for i in range(n_ext):
        fid, blk, size, off, lid = struct.unpack_from('<QIIII', data, pos + 4 + i * 24)
        ext.append((fid, size, off * blk, lid))
    return {'banks': banks, 'stm': stm, 'ext': ext, 'data': data}

def bnk_info(bnk):
    pos = 0
    sources = []
    didx = set()
    while pos + 8 <= len(bnk):
        tag = bnk[pos:pos+4]; (size,) = struct.unpack_from('<I', bnk, pos+4)
        body = pos + 8
        if tag == b'DIDX':
            for i in range(size // 12):
                (mid,) = struct.unpack_from('<I', bnk, body + i * 12)
                didx.add(mid)
        elif tag == b'HIRC':
            (count,) = struct.unpack_from('<I', bnk, body)
            p = body + 4
            for _ in range(count):
                htype = bnk[p]; (hsize,) = struct.unpack_from('<I', bnk, p+1)
                hbody = p + 5
                if htype == 2:
                    st = bnk[hbody + 8]
                    sid, = struct.unpack_from('<I', bnk, hbody + 9)
                    sources.append((sid, st))
                elif htype == 11:
                    p2 = hbody + 5
                    (nsrc,) = struct.unpack_from('<I', bnk, p2)
                    p2 += 4
                    for _ in range(nsrc):
                        st = bnk[p2 + 4]
                        sid, = struct.unpack_from('<I', bnk, p2 + 5)
                        sources.append((sid, st))
                        p2 += 14
                p += 5 + hsize
        pos = body + size
    return sources, didx

def pck_summary(path):
    pk = parse_akpk(path)
    srcs = []
    didx = set()
    bank_map = {}
    for fid, size, off, lid in pk['banks']:
        blob = pk['data'][off:off+size]
        s, d = bnk_info(blob)
        srcs.extend(s)
        didx |= d
        bank_map[fid] = blob
    return pk, srcs, didx, bank_map

BETA_BK = r'C:\Users\jshu\Desktop\ZZZ\audio-import-backup\beta-originals'
LIVE_SA = r'C:\Games\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero_Data\StreamingAssets\Audio\Windows\Full'
LIVE_PS = r'C:\Games\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero_Data\Persistent\Audio\Windows\Full'
BETA_SA = r'C:\Users\jshu\Desktop\ZZZ\CNBetaWin3.1.3\ZenlessZoneZeroBeta_Data\StreamingAssets\Audio\Windows\Full'

def live_path(lang, name):
    for base in (LIVE_SA, LIVE_PS):
        p = os.path.join(base, lang, name)
        if os.path.exists(p):
            return p
    return None

for lang, beta_sb in [('En', os.path.join(BETA_BK, 'En', 'SoundBank_En_0.pck')),
                      ('Jp', os.path.join(BETA_BK, 'Jp', 'SoundBank_Jp_0.pck')),
                      ('Cn', os.path.join(BETA_SA, 'Cn', 'SoundBank_Cn_0.pck'))]:
    live_sb = live_path(lang, f'SoundBank_{lang}_0.pck')
    print(f'=== {lang}: beta={beta_sb}')
    print(f'    live={live_sb} ({os.path.getsize(live_sb):,} B)' if live_sb else '    live=MISSING')
    if not live_sb:
        continue
    bpk, bsrc, bdidx, bbanks = pck_summary(beta_sb)
    lpk, lsrc, ldidx, lbanks = pck_summary(live_sb)
    bids, lids = set(bbanks), set(lbanks)
    common = bids & lids
    print(f'  bank IDs: beta={len(bids)}, live={len(lids)}, common={len(common)} '
          f'({100*len(common)/len(bids):.1f}% of beta)')
    same_bytes = sum(1 for i in common if bbanks[i] == lbanks[i])
    print(f'  identical bank bytes among common: {same_bytes}/{len(common)}')
    b_inmem = {sid for sid, st in bsrc if st in (0, 1)}
    b_stream = {sid for sid, st in bsrc if st == 2}
    cov_inmem = b_inmem & ldidx
    print(f'  beta in-memory media refs: {len(b_inmem)}; covered by LIVE didx: {len(cov_inmem)} '
          f'({100*len(cov_inmem)/max(1,len(b_inmem)):.1f}%)')
    # streamed coverage: live Streamed + beta numbered pcks (externals LUT u64)
    stm_p = live_path(lang, f'Streamed_{lang}_0.pck')
    stm_ids = {fid for fid, *_ in parse_akpk(stm_p)['stm']} if stm_p else set()
    num_ext = set()
    for np_ in glob.glob(os.path.join(BETA_SA, lang, '[0-9]*.pck')):
        pk = parse_akpk(np_)
        num_ext |= {fid for fid, *_ in pk['ext']}
        num_ext |= {fid for fid, *_ in pk['stm']}
    cov_s = b_stream & (stm_ids | num_ext)
    print(f'  beta streamed refs: {len(b_stream)}; covered by live Streamed + beta numbered pcks: '
          f'{len(cov_s)} ({100*len(cov_s)/max(1,len(b_stream)):.1f}%)  '
          f'[Streamed alone: {len(b_stream & stm_ids)}, numbered alone: {len(b_stream & num_ext)}]')
    del bpk, lpk, bbanks, lbanks
