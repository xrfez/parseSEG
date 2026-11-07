import sys, struct
d = open(sys.argv[1], 'rb').read()
def nib(b, n): return (b[n>>1] >> 4) if n % 2 == 0 else (b[n>>1] & 15)
def bcd(b, first, cnt):
    v = 0
    for n in range(first, first+cnt):
        x = nib(b, n)
        if x > 9: return 'F'*cnt if all(nib(b,k)==15 for k in range(first,first+cnt)) else f'bad{x:X}'
        v = v*10 + x
    return v
u16 = lambda b,o: struct.unpack('>H', b[o:o+2])[0]
u24 = lambda b,o: int.from_bytes(b[o:o+3], 'big')
i24 = lambda b,o: int.from_bytes(b[o:o+3], 'big', signed=True)
g1 = d[0:32]
B = lambda byte1: (byte1-1)*2   # nibble index of byte (1-based) high nibble
gh = dict(file=bcd(g1,B(1),4), fmt=bcd(g1,B(3),4), K=g1[4:10].hex(), yr=bcd(g1,B(11),2),
  addGH=nib(g1,B(12)), day=bcd(g1,B(12)+1,3), hms=(bcd(g1,B(14),2),bcd(g1,B(15),2),bcd(g1,B(16),2)),
  mfr=bcd(g1,B(17),2), serial=bcd(g1,B(18),4), b20_22=g1[19:22].hex(), bsi16=g1[22],
  pol=nib(g1,B(24)), b24L=nib(g1,B(24)+1), b25=g1[24], rtype=nib(g1,B(26)), rlen=bcd(g1,B(26)+1,3),
  st=bcd(g1,B(28),2), cs=bcd(g1,B(29),2), sk=bcd(g1,B(30),2), ec=bcd(g1,B(31),2), ex=bcd(g1,B(32),2))
print('GH1', gh)
g2 = d[32:64]
print('GH2 extFile', u24(g2,0), 'extCS', u16(g2,3), 'extEC', u16(g2,5), 'extEX', u16(g2,7), 'b10', g2[9],
      'rev', g2[10], g2[11], 'GT', u16(g2,12), 'extRL', u24(g2,14), 'b18', g2[17], 'blk#', g2[18], 'b20', g2[19],
      'seq', u16(g2,20), 'rest', g2[22:32].hex())
nGH = 1 + (gh['addGH'] if gh['addGH'] != 15 else None)
pos = 64
for k in range(3, nGH+1):
    g = d[pos:pos+32]
    print(f'GH{k} raw', g.hex(), '| blk#', g[18], 'srcLine', int.from_bytes(g[3:8],'big',signed=True)/65536,
          'srcPt', int.from_bytes(g[8:13],'big',signed=True)/65536, 'idx', g[13], 'set', g[19])
    pos += 32
cs = gh['cs'] if isinstance(gh['cs'], int) else u16(g2,3)
csds = []
for s in range(gh['st']):
    for c in range(cs):
        x = d[pos:pos+32]
        mp = ((x[7]&0x7F)<<8 | x[6]) / 1024 * (-1 if x[7]&0x80 else 1)
        e = dict(st=bcd(x,0,2), cs=bcd(x,2,2), t0=u16(x,2)*2, t1=u16(x,4)*2, mp=mp, nch=bcd(x,B(9),4),
                 ctype=nib(x,B(11)), z11L=nib(x,B(11)+1), sc=bcd(x,B(12),1), gain=nib(x,B(12)+1),
                 af=bcd(x,B(13),4), afs=bcd(x,B(15)+1,3), lc=bcd(x,B(17),4), lcs=bcd(x,B(19)+1,3),
                 n1=bcd(x,B(21),4), extCS=u16(x,26), efh=nib(x,B(29)), the=nib(x,B(29)+1), vstack=x[29], strm=x[30], arr=x[31])
        print('CSD', e); csds.append(e); pos += 32
    pos += 32*gh['sk']
ec = gh['ec'] if isinstance(gh['ec'], int) else u16(g2,5)
ex = gh['ex'] if isinstance(gh['ex'], int) else u16(g2,7)
print('ext hdr', ec, 'blocks @', pos, '| ext-ernal', ex, 'blocks'); pos += 32*(ec+ex)
print('traces start @', pos)
fmtbytes = {8058:4, 8038:4, 8036:3, 8048:4}
ntr = 0
while pos + 20 <= len(d):
    t = d[pos:pos+20]
    the = t[9]
    ext = d[pos+20:pos+20+32*the]
    ns = u24(ext,7) if the else None
    if ntr < 4 or pos + 20 + 32*the + ns*4 >= len(d):
        print(f'TR@{pos} file', bcd(t,0,4), 'st', bcd(t,4,2), 'cs', bcd(t,6,2), 'tr', bcd(t,8,4), 'tw', u24(t,6)/256,
              'THE', the, 'skew', t[10], 'edit', t[11], 'tbw', u24(t,12)/256, 'extCS', u16(t,15), 'extFile', u24(t,17),
              '| ext1 rl', i24(ext,0), 'rp', i24(ext,3), 'ridx', ext[6], 'ns', ns, 'sensor', ext[20] if the else None,
              'first samples', [round(v,4) for v in struct.unpack('>3f', d[pos+20+32*the:pos+32+32*the])] if gh['fmt']==8058 else '')
    if ns is None: print('no extension: cannot size trace'); break
    pos += 20 + 32*the + ns*fmtbytes[gh['fmt']]; ntr += 1
print('traces', ntr, 'end pos', pos, 'file size', len(d), 'remaining', d[pos:pos+64].hex())
