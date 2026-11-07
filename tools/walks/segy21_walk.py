"""Walk a SEG-Y rev 2.1 file using the tables in docs/spec/segy_rev2_1.md.
Prints decoded header fields and summaries only (no sample dumps)."""
import sys, struct, codecs, re, collections

path = sys.argv[1]
b = open(path, 'rb').read()
N = len(b)
cover = []  # (start, end_excl, label)

def add(s, e, lab):
    cover.append((s, e, lab))

# ---- byte order from 3297-3300 (file offset 3296) ----
bom = b[3296:3300]
if bom == b'\x01\x02\x03\x04' or bom == b'\0\0\0\0':
    order = 'big'
elif bom == b'\x04\x03\x02\x01':
    order = 'little'
elif bom == b'\x02\x01\x04\x03':
    order = 'pairswap'
else:
    order = 'unknown'

def fix(raw):
    if order == 'little':
        return raw[::-1]
    if order == 'pairswap':
        out = bytearray()
        for i in range(0, len(raw), 2):
            out += raw[i:i+2][::-1]
        return bytes(out)
    return raw

def rd(buf, off1, ln, enc):
    """off1 = 1-based byte position within buf."""
    raw = fix(buf[off1-1:off1-1+ln])
    if enc in ('i16', 'i32', 'i64'):
        return int.from_bytes(raw, 'big', signed=True)
    if enc in ('u8', 'u16', 'u32', 'u64'):
        return int.from_bytes(raw, 'big', signed=False)
    if enc == 'f64':
        return struct.unpack('>d', raw)[0]
    if enc == 'f32':
        return struct.unpack('>f', raw)[0]
    raise ValueError(enc)

# ---- textual header ----
tx = b[0:3200]
add(0, 3200, 'textual header')
enc_tx = 'ebcdic' if tx[0] == 0xC3 else ('ascii' if tx[0] == 0x43 else '?')
ttxt = codecs.decode(tx, 'cp037') if enc_tx == 'ebcdic' else tx.decode('latin1')
print('TEXTUAL  enc=%s  C01=%r' % (enc_tx, ttxt[:40]))
for k in range(40):
    line = ttxt[k*80:(k+1)*80]
    if 'SEG' in line.upper() and 'REV' in line.upper():
        print('  revision card C%02d: %r' % (k+1, line.rstrip()))
    if k == 38 or k == 39:
        print('  C%02d: %r' % (k+1, line.rstrip()))

# ---- binary header (absolute numbering, block starts at file byte 3201) ----
bh = b[3200:3600]
add(3200, 3600, 'binary header')
def B(a, ln, enc):
    return rd(bh, a-3200, ln, enc)

BIN = [
 (3201,4,'i32','jobId'),(3205,4,'i32','lineNumber'),(3209,4,'i32','reelNumber'),
 (3213,2,'i16','dataTracesPerEnsemble'),(3215,2,'i16','auxTracesPerEnsemble'),
 (3217,2,'u16','sampleInterval'),(3219,2,'u16','sampleIntervalOrig'),
 (3221,2,'u16','samplesPerTrace'),(3223,2,'u16','samplesPerTraceOrig'),
 (3225,2,'i16','formatCode'),(3227,2,'i16','ensembleFold'),(3229,2,'i16','traceSorting'),
 (3231,2,'i16','verticalSumCode'),(3233,2,'i16','sweepFreqStart'),(3235,2,'i16','sweepFreqEnd'),
 (3237,2,'i16','sweepLength'),(3239,2,'i16','sweepType'),(3241,2,'i16','sweepChannel'),
 (3243,2,'i16','sweepTaperStart'),(3245,2,'i16','sweepTaperEnd'),(3247,2,'i16','taperType'),
 (3249,2,'i16','correlated'),(3251,2,'i16','binaryGainRecovered'),(3253,2,'i16','amplitudeRecovery'),
 (3255,2,'i16','measurementSystem'),(3257,2,'i16','impulsePolarity'),(3259,2,'i16','vibratoryPolarity'),
 (3261,4,'u32','extDataTracesPerEnsemble'),(3265,4,'u32','extAuxTracesPerEnsemble'),
 (3269,4,'u32','extSamplesPerTrace'),(3273,8,'f64','extSampleInterval'),
 (3281,8,'f64','extSampleIntervalOrig'),(3289,4,'u32','extSamplesPerTraceOrig'),
 (3293,4,'u32','extEnsembleFold'),(3297,4,'u32','byteOrderMarker'),
 (3501,1,'u8','segyMajor'),(3502,1,'u8','segyMinor'),(3503,2,'i16','fixedLengthTraces'),
 (3505,2,'i16','numExtTextHeaders'),(3507,2,'u16','maxAddlTraceHeaders'),
 (3509,2,'u16','surveyType'),(3511,2,'i16','timeBasisCode'),
 (3513,8,'u64','numTraces'),(3521,8,'u64','firstTraceOffset'),(3529,4,'i32','numTrailerRecords'),
]
H = {}
for a, ln, enc, nm in BIN:
    if nm == 'byteOrderMarker':
        v = int.from_bytes(bh[a-3201:a-3201+4], 'big')  # raw, never swapped
    else:
        v = B(a, ln, enc)
    H[nm] = v
# unassigned checks
un1 = bh[3301-3201:3500-3200]; un2 = bh[3533-3201:3600-3200]
print('BINARY   byteOrder raw=0x%08X -> %s' % (H['byteOrderMarker'], order))
for a, ln, enc, nm in BIN:
    v = H[nm]
    if v not in (0, 0.0) or nm in ('numExtTextHeaders', 'maxAddlTraceHeaders', 'numTrailerRecords', 'numTraces', 'firstTraceOffset', 'surveyType', 'timeBasisCode'):
        print('  %d-%d %-26s %s' % (a, a+ln-1, nm, ('0x%08X' % v) if nm == 'byteOrderMarker' else v))
print('  unassigned 3301-3500 all zero:', not any(un1), ' 3533-3600 all zero:', not any(un2))

fmt = H['formatCode']
BPS = {1:4,2:4,3:2,4:4,5:4,6:8,7:3,8:1,9:8,10:4,11:2,12:8,15:3,16:1}
bps = BPS[fmt]
ns_eff = H['extSamplesPerTrace'] or H['samplesPerTrace']
dt_eff = H['extSampleInterval'] or H['sampleInterval']
nAddl = H['maxAddlTraceHeaders']
print('  effective ns=%d dt=%s bps=%d nAddl=%d' % (ns_eff, dt_eff, bps, nAddl))

# ---- extended textual headers ----
def is_stanza_start(blk):
    return blk[:2] in (b'((', b'\x4d\x4d')

def stanza_name(blk):
    if blk[:2] == b'((':
        e = blk.find(b'))'); return blk[:e+2].decode('ascii'), e+2, 'ascii'
    e = blk.find(b'\x5d\x5d'); return codecs.decode(blk[:e+2], 'cp037'), e+2, 'ebcdic'

def norm(name):
    return re.sub(r'\s', '', name).upper()

off = 3600
nExt = H['numExtTextHeaders']
stanzas = []
recs = 0
if nExt != 0:
    while True:
        blk = b[off:off+3200]
        assert len(blk) == 3200, 'ran off end in ext headers'
        if is_stanza_start(blk):
            nm, hl, enc = stanza_name(blk)
            stanzas.append([nm, off, 1, enc, hl])
        else:
            stanzas[-1][2] += 1
        add(off, off+3200, 'ext textual record %d' % recs)
        off += 3200; recs += 1
        if nExt > 0 and recs == nExt:
            break
        if nExt == -1 and is_stanza_start(blk) and norm(stanza_name(blk)[0]) == '((SEG:ENDTEXT))':
            break
print('EXTTEXT  records=%d  (bin 3505=%d)  ends at file offset %d' % (recs, nExt, off))
for nm, so, nrec, enc, hl in stanzas:
    body = b[so+hl:so+nrec*3200]
    parts = nm[2:-2].split(':')
    info = ''
    if len(parts) >= 4 and parts[3].strip().isdigit():
        size = int(parts[3]); data = body[:size]; pad = body[size:]
        info = 'declared bytes=%d; pad bytes=%d all-NUL=%s; magic=%r; tail=%r' % (
            size, len(pad), not any(pad), data[:8], data[-8:])
    else:
        st = body.rstrip(b' ')
        info = 'text len=%d; pad=%d (spaces)' % (len(st), len(body)-len(st))
    print('  @%-7d recs=%-3d %-4s %-40s %s' % (so, nrec, enc, nm, info))
    if norm(nm) == '((SEG:ENDTEXT))':
        print('    EndText rest blank:', set(body) <= {0x20})

# ---- first-trace offset cross-check ----
if H['firstTraceOffset']:
    print('  bin 3521 firstTraceOffset=%d vs walked %d' % (H['firstTraceOffset'], off))

# ---- traces ----
TRH = [
 (1,4,'i32','traceSeqLine'),(5,4,'i32','traceSeqFile'),(9,4,'i32','fieldRecord'),
 (13,4,'i32','traceNumberInField'),(17,4,'i32','energySourcePoint'),(21,4,'i32','ensembleNumber'),
 (25,4,'i32','traceInEnsemble'),(29,2,'i16','traceIdCode'),(31,2,'i16','numVertSummed'),
 (33,2,'i16','numHorzStacked'),(35,2,'i16','dataUse'),(37,4,'i32','offset'),
 (41,4,'i32','receiverElevation'),(69,2,'i16','elevationScalar'),(71,2,'i16','coordinateScalar'),
 (73,4,'i32','sourceX'),(77,4,'i32','sourceY'),(81,4,'i32','groupX'),(85,4,'i32','groupY'),
 (89,2,'i16','coordinateUnits'),(115,2,'u16','numSamples'),(117,2,'u16','sampleInterval'),
 (157,2,'i16','year'),(167,2,'i16','timeBasisCode'),(181,4,'i32','cdpX'),(185,4,'i32','cdpY'),
 (189,4,'i32','inlineNumber'),(193,4,'i32','crosslineNumber'),(215,2,'i16','timeScalar'),
]
trailer_start = None
ntr = 0
stats = collections.defaultdict(lambda: [None, None])
names = collections.Counter()
nonzero_ranges = collections.Counter()
first = None
expect = H['numTraces'] if H['numTraces'] else None
while off < N:
    if expect is not None and ntr == expect:
        break
    if H['numTrailerRecords'] > 0 and N - off == H['numTrailerRecords']*3200:
        break
    th = b[off:off+240]
    assert len(th) == 240
    vals = {nm: rd(th, a, ln, enc) for a, ln, enc, nm in TRH}
    names[th[232:240]] += 1
    nh = 1
    ns = vals['numSamples']
    if nAddl:
        e1 = b[off+240:off+480]
        assert e1[232:240] in (b'SEG00001', codecs.encode('SEG00001', 'cp037'))
        ens = rd(e1, 137, 4, 'u32')
        if ens: ns = ens
        n1 = rd(e1, 157, 2, 'u16') or nAddl
        nh = 1 + n1
    if H['fixedLengthTraces'] == 1:
        ns = ns_eff
    recl = 240*nh + ns*bps
    add(off, off+240*nh, 'trace %d headers' % ntr)
    add(off+240*nh, off+recl, 'trace %d data' % ntr)
    if first is None:
        first = (off, vals)
    for k, v in vals.items():
        s = stats[k]
        s[0] = v if s[0] is None else min(s[0], v)
        s[1] = v if s[1] is None else max(s[1], v)
    if vals['numSamples'] != ns_eff or vals['sampleInterval'] != dt_eff:
        print('  trace %d ns/dt mismatch %d/%d' % (ntr, vals['numSamples'], vals['sampleInterval']))
    off += recl; ntr += 1
print('TRACES   count=%d  record=%d bytes (240*%d + %d*%d)  first @%d  end @%d' % (
    ntr, recl, nh, ns, bps, first[0], off))
print('  bytes 233-240 names:', dict(names))
for k, (lo, hi) in stats.items():
    print('  %-20s min=%s max=%s' % (k, lo, hi))

# ---- trailer ----
rest = N - off
print('TRAILER  remaining bytes=%d (bin 3529=%d)' % (rest, H['numTrailerRecords']))
if rest:
    add(off, N, 'trailer')

# ---- tiling check ----
cover.sort()
pos = 0; ok = True
for s, e, lab in cover:
    if s != pos:
        ok = False; print('GAP/OVERLAP at', pos, s, lab)
    pos = e
print('TILING   exact=%s  covered=%d  file=%d' % (ok and pos == N, pos, N))
