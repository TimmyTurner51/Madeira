import struct, sys

def check(path):
    d=open(path,'rb').read()
    pe=struct.unpack_from('<I',d,0x3c)[0]
    mach=struct.unpack_from('<H',d,pe+4)[0]
    nsec=struct.unpack_from('<H',d,pe+6)[0]
    opt=pe+24
    magic=struct.unpack_from('<H',d,opt)[0]
    dd=opt+(112 if magic==0x20b else 96)
    exp_rva,exp_sz=struct.unpack_from('<II',d,dd)
    secoff=opt+struct.unpack_from('<H',d,pe+20)[0]
    secs=[]
    for i in range(nsec):
        o=secoff+40*i
        vs,va,rs,ptr=struct.unpack_from('<IIII',d,o+8)
        secs.append((va,max(vs,rs),ptr,rs))
    def r2o(rva):
        for va,sz,ptr,rs in secs:
            if va<=rva<va+sz: return ptr+(rva-va)
        return None
    if not exp_rva: return f"{path}: no exports"
    eo=r2o(exp_rva)
    nnames=struct.unpack_from('<I',d,eo+24)[0]
    afn=struct.unpack_from('<I',d,eo+28)[0]
    anames=struct.unpack_from('<I',d,eo+32)[0]
    aord=struct.unpack_from('<I',d,eo+36)[0]
    HOOK=bytes.fromhex('488da42400000000ff25')   # mov rsp,[rsp]; jmp [rip+x]
    BARE=bytes.fromhex('ff25')
    hot=bare=other=0
    samples=[]
    for i in range(min(nnames,4000)):
        nr=struct.unpack_from('<I',d,r2o(anames)+4*i)[0]
        orv=struct.unpack_from('<H',d,r2o(aord)+2*i)[0]
        frva=struct.unpack_from('<I',d,r2o(afn)+4*orv)[0]
        off=r2o(frva)
        if off is None: continue
        b=d[off:off+16]
        if b.startswith(HOOK): hot+=1
        elif b.startswith(BARE): bare+=1; 
        else:
            other+=1
            if len(samples)<3: samples.append((frva,b.hex()))
        if b.startswith(BARE) and len(samples)<6: samples.append((frva,b.hex()))
    print(f"{path.split('/')[-1]:16} machine={mach:#x} exports={nnames} hotpatch={hot} bare-ff25={bare} other={other}")
    for s in samples: print("    sample", hex(s[0]), s[1])

for p in sys.argv[1:]: check(p)
