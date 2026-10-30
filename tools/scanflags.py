"""Find every CALL to IsOnlineMultiplay (stub 0x140828C80) that is followed within 24 bytes by a byte compare against a field
in 0x200..0x23F of some register (cmp byte ptr [reg+disp32], imm8 = 80 /7 with mod=10, or movzx eax, byte ptr [reg+disp32]).
Prints the return address and the offsets compared: the large-poly / memory "partner ready" flags of session 10."""
import sys, struct
exe = sys.argv[1]
data = open(exe, 'rb').read()
e = struct.unpack_from('<I', data, 0x3C)[0]
nsec = struct.unpack_from('<H', data, e + 6)[0]
opt = struct.unpack_from('<H', data, e + 20)[0]
base = struct.unpack_from('<Q', data, e + 24 + 24)[0]
o = e + 24 + opt
TARGET = 0x140828C80
for i in range(nsec):
    name = data[o:o + 8].rstrip(b'\0').decode(errors='replace')
    vs, va, rs, ra = struct.unpack_from('<IIII', data, o + 8)   # VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData
    o += 40
    sec = data[ra:ra + rs]
    pos = sec.find(b'\xE8')
    while pos != -1 and pos + 5 <= len(sec):
        rel = struct.unpack_from('<i', sec, pos + 1)[0]
        addr = base + va + pos
        if addr + 5 + rel == TARGET:
            tail = sec[pos + 5:pos + 5 + 40]
            offs = []
            for k in range(len(tail) - 6):
                b0, b1 = tail[k], tail[k + 1]
                if b0 == 0x80 and (b1 >> 6) == 2 and ((b1 >> 3) & 7) == 7:
                    d = struct.unpack_from('<i', tail, k + 2)[0]
                    if 0x200 <= d < 0x240: offs.append('cmp+%X' % d)
                if b0 == 0x0F and b1 == 0xB6 and k + 7 <= len(tail) and (tail[k + 2] >> 6) == 2:
                    d = struct.unpack_from('<i', tail, k + 3)[0]
                    if 0x200 <= d < 0x240: offs.append('movzx+%X' % d)
            if offs: print('return 0x%X (%s): %s' % (addr + 5, name, ' '.join(offs)))
        pos = sec.find(b'\xE8', pos + 1)
