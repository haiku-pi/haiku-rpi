#!/usr/bin/env python3
# lookupsim.py PROGRAM LIBDIR[:LIBDIR...] — offline replay of the runtime loader's symbol lookups for PROGRAM:
# its load order (breadth first over DT_NEEDED), then for every symbol its images' relocations
# reference, the images searched before the definition; prints the SysV and GNU-hash misses per image.
# Uses the host's python only (no pyelftools).
"""Replay the runtime loader's global symbol lookups for a program: load order (breadth-first over
DT_NEEDED), then for each undefined symbol of each image the images searched until a definition."""
import struct, sys, os, collections
def elf(path):
    d=open(path,'rb').read()
    shoff,=struct.unpack_from('<Q',d,0x28); shentsize,shnum,shstrndx=struct.unpack_from('<HHH',d,0x3a)
    secs=[]
    for i in range(shnum):
        nm,typ,fl,addr,off,size,link,info,align,ent=struct.unpack_from('<IIQQQQIIQQ',d,shoff+i*shentsize)
        secs.append(dict(nm=nm,typ=typ,off=off,size=size,link=link))
    shs=secs[shstrndx]
    def name(s): o=shs['off']+s['nm']; return d[o:d.index(b'\0',o)].decode()
    S={name(s):s for s in secs}
    ds=S['.dynsym']; st=S['.dynstr']
    syms=[]
    for i in range(ds['size']//24):
        n,info,other,shndx,val,size=struct.unpack_from('<IBBHQQ',d,ds['off']+i*24)
        o=st['off']+n; syms.append((d[o:d.index(b'\0',o)].decode(),info>>4,shndx))
    dyn=S['.dynamic']; needed=[]
    for i in range(dyn['size']//16):
        tag,val=struct.unpack_from('<qQ',d,dyn['off']+i*16)
        if tag==1: o=st['off']+val; needed.append(d[o:d.index(b'\0',o)].decode())
    refs=set()
    for sec in ('.rela.dyn','.rela.plt'):
        if sec in S:
            r=S[sec]
            for j in range(r['size']//24):
                off,info,add=struct.unpack_from('<QQq',d,r['off']+j*24)
                si=info>>32
                if si and syms[si][1] in (1,2): refs.add(syms[si][0])
    return dict(syms=syms, needed=needed, gnu='.gnu.hash' in S, refs=refs,
                defined={n for n,b,sh in syms if sh!=0 and b in (1,2) and n},
                undef=[n for n,b,sh in syms if sh==0 and n])
paths=sys.argv[2].split(':')
def find(lib):
    for p in paths:
        f=os.path.join(p,lib)
        if os.path.exists(f): return f
    return None
root=sys.argv[1]
order=[('root',root)]; loaded={}; i=0
loaded['root']=elf(root)
while i<len(order):
    nm,_=order[i]
    for n in loaded[nm]['needed']:
        if n not in loaded:
            f=find(n)
            if f is None: print("missing",n); continue
            loaded[n]=elf(f); order.append((n,f))
    i+=1
print("load order:", ", ".join("%s%s"%(n,"" if loaded[n]['gnu'] else "(sysv)") for n,_ in order))
sysv=collections.Counter(); gnu=collections.Counter(); total=0
for nm,_ in order:
    for s in loaded[nm]['refs']:
        total+=1
        for m,_ in order:
            if s in loaded[m]['defined']: break
            (gnu if loaded[m]['gnu'] else sysv)[m]+=1
print("lookups",total,"SysV misses",sum(sysv.values()),"GNU misses",sum(gnu.values()))
for k,v in sysv.most_common(): print("  sysv miss %6d %s"%(v,k))
