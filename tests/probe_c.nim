import std/[random, strutils]
import parseSEGD/segy/[reader, fields]

proc tryScal(kindXml: string, setter: proc(t: var SegyTrace)) =
  var f = SegyFile(byteOrder: boBig, format: sfInt16, formatKnown: true)
  f.binary = SegyBinaryHeader(segyMajor: 2, segyMinor: 1, formatCode: 3)
  f.layout = merge(standardLayout(f.binary.rulesRevision), parseLayout(
    "<segy-layout><entry name=\"co_scal\" byte=\"" & kindXml & "/></segy-layout>"))
  var t: SegyTrace
  t.header.sourceX = 100
  setter(t)
  try:
    var v: float64
    discard fieldValue(f, t, "sht_x", v)
    echo kindXml, " -> ", v
  except Defect as e:
    echo kindXml, " DEFECT ", e.name, ": ", e.msg
  except CatchableError as e:
    echo kindXml, " raised ", e.name

tryScal("1\" type=\"int4\"", proc(t: var SegyTrace) = t.header.traceSeqLine = 1_000_000)
tryScal("1\" type=\"ieee32\"", proc(t: var SegyTrace) = t.header.traceSeqLine = int32(0x7FC00000))
tryScal("1\" type=\"uint8\"", proc(t: var SegyTrace) = t.header.traceSeqLine = -1)

# parseLayout fuzz
randomize(42)
let base = "<segy-layout name=\"x\"><desc>d</desc><entry name=\"iline\" byte=\"13\" type=\"int4\"/><extension name=\"SEG00001\"><entry name=\"a\" byte=\"1\" type=\"int8\" if-non-zero=\"1\"/></extension></segy-layout>"
let alphabet = "<>/=\"'&;!?-[]# \n\x00abc"
var defects = 0
for i in 0..20000:
  var s = base
  let nmut = rand(1..6)
  for k in 0..<nmut:
    case rand(2)
    of 0: s[rand(s.high)] = alphabet[rand(alphabet.high)]
    of 1: s.insert($alphabet[rand(alphabet.high)], rand(s.len))
    else:
      let p = rand(s.high); s.delete(p..p)
  try:
    discard parseLayout(s)
  except ValueError: discard
  except Defect as e:
    inc defects
    if defects < 4: echo "DEFECT on ", s.escape, ": ", e.name, " ", e.msg
  except CatchableError as e:
    inc defects
    if defects < 4: echo "OTHER on ", s.escape, ": ", e.name, " ", e.msg
echo "fuzz defects/other: ", defects
for s in ["", "<", "<segy-layout", "<!DOCTYPE x [<!ENTITY a \"b\">]><segy-layout/>", "&#99999999999;<segy-layout/>", "<segy-layout>&#xFFFFFFFFFF;</segy-layout>", "<segy-layout><entry name='x' byte='0013' type='int4'/></segy-layout>"]:
  try:
    let l = parseLayout(s); echo "ok ", s.escape, " ", l.entries.len
  except ValueError as e: echo "VE ", s.escape, " ", e.msg
  except Defect as e: echo "DEFECT ", s.escape, " ", e.name
