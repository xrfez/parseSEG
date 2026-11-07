import sys, struct, collections, datetime
f = open(sys.argv[1], 'rb'); size = f.seek(0, 2); f.seek(0)
def nib(b, n): return (b[n>>1] >> 4) if n % 2 == 0 else (b[n>>1] & 15)
def bcd(b, byte1, cnt, start_low=False):
    first = (byte1-1)*2 + (1 if start_low else 0); v = 0
    for n in range(first, first+cnt):
        x = nib(b, n)
        if x > 9: return 'F'
        v = v*10 + x
    return v
U = lambda b,o,n: int.from_bytes(b[o-1:o-1+n], 'big')
I = lambda b,o,n: int.from_bytes(b[o-1:o-1+n], 'big', signed=True)
F32 = lambda b,o: struct.unpack('>f', b[o-1:o+3])[0]
rec = 0; start = 0
while start < size and rec < 3:
    f.seek(start); h = f.read(32*3)
    g1, g2, g3 = h[0:32], h[32:64], h[64:96]
    addGH = nib(g1, 22); nGH = 1 + (U(g2,23,2) if addGH == 15 else addGH)
    nST = bcd(g1,28,2); nCS = U(g2,4,2) if g1[28]==0xFF else bcd(g1,29,2)
    nSK = U(g2,9,2) if g1[29]==0xFF else bcd(g1,30,2)
    nEC = U(g2,6,3) if g1[30]==0xFF else bcd(g1,31,2)
    nEX = U(g2,28,3) if g1[31]==0xFF else bcd(g1,32,2)
    print(f'REC {rec} @ {start}: file', bcd(g1,1,4) if g1[0]!=0xFF else U(g2,1,3), 'fmt', bcd(g1,3,4),
          'date 20%02d day %s %s:%s:%s' % (bcd(g1,11,2), bcd(g1,12,3,True), bcd(g1,14,2), bcd(g1,15,2), bcd(g1,16,2)),
          'mfr', bcd(g1,17,2), 'bsi', g1[22], 'domSI', U(g2,25,3), 'rtype', nib(g1,50), 'rlen', U(g2,17,4) if nib(g1,51)==15 else bcd(g1,26,3,True))
    print('  nGH', nGH, 'ST', nST, 'CS', nCS, 'SK', nSK, 'EC', nEC, 'EX', nEX, 'rev', g2[10], g2[11], 'GT', U(g2,13,4), 'recSet', U(g2,21,2), 'GH2type', hex(g2[31]))
    ts = I(g3,1,8)
    print('  GH3 TZ', ts, '=GPS', datetime.datetime(1980,1,6)+datetime.timedelta(microseconds=ts), 'recordSize', U(g3,9,8), 'dataSize', U(g3,17,8),
          'headerSize', U(g3,25,4), 'ERM', g3[28], 'RTM', g3[29], 'type', hex(g3[31]))
    f.seek(start); hdr = f.read(32*nGH)
    types = [hex(hdr[32*k+31]) for k in range(1, nGH)]
    print('  GH block types:', types)
    for k in range(3, nGH):
        b = hdr[32*k:32*k+32]
        if 0x10 <= b[31] <= 0x14: print('   text', hex(b[31]), repr(b[:31].decode('ascii','replace').strip()))
    pos = start + 32*nGH; css = []
    for s in range(nST):
        for c in range(nCS):
            f.seek(pos); x = f.read(96)
            cs = dict(st=bcd(x,1,2), cs=U(x,2,2), ctype=hex(x[3]), t0=I(x,5,4), t1=I(x,9,4), ns=U(x,13,4), dsm=F32(x,17),
                      nch=U(x,21,3), si=U(x,24,3), the=x[27], unit=x[61], types=(hex(x[31]),hex(x[63]),hex(x[95])),
                      desc=x[68:95].decode('ascii','replace').strip())
            css.append(cs); pos += 96
        pos += 32*nSK
    for cs in css: print('  CSD', cs)
    pos += 32*(nEC + nEX)
    calcHdr = pos - start
    print('  headerSize calc', calcHdr, 'vs GH3', U(g3,25,4))
    bps = {8058:4, 8038:4, 8036:3, 8048:4, 8080:8}[bcd(g1,3,4)]
    ntr = 0; thetypes = collections.Counter()
    for cs in css:
        for t in range(cs['nch']):
            f.seek(pos); th = f.read(20 + 32*cs['the'])
            if t == 0 or t == cs['nch']-1:
                e = th[20:52]
                print(f'   TR cs{cs["cs"]} #{t+1} @{pos}: file', bcd(th,1,4), 'st', bcd(th,3,2), 'cs', bcd(th,4,2), 'tr', bcd(th,5,4),
                      'THE', th[9], '| rl', I(e,1,3), 'rp', I(e,4,3), 'ridx', e[6], 'grp', e[8], 'ns', U(e,25,4), 'sensor', e[20], 'unit', e[30], 'type', hex(e[31]))
            for k in range(cs['the']): thetypes[hex(th[20+32*k+31])] += 1
            pos += 20 + 32*cs['the'] + cs['ns']*bps; ntr += 1
    print('  traces', ntr, 'THE block types', dict(thetypes), 'dataSize calc', pos - start, 'vs GH3', U(g3,17,8))
    gt = U(g2,13,4); pos += 32*gt
    print('  recordSize calc', pos - start, 'vs GH3', U(g3,9,8), '| file size', size)
    start = pos; rec += 1
