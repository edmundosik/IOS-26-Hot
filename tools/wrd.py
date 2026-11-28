import sys,re,zlib,base64,os
from PIL import Image
log=open(sys.argv[1],errors='replace').read().splitlines()
out=sys.argv[2];os.makedirs(out,exist_ok=True)
hdr={};chunks={}
for l in log:
    m=re.search(r'WRD (\w+) (\d) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)',l)
    if m: k=(m[1],m[2]);hdr[k]=tuple(int(x) for x in m.groups()[2:]);continue
    m=re.search(r'WRZ (\w+) (\d) (\d+) (\S+)',l)
    if m: chunks.setdefault((m[1],m[2]),{})[int(m[3])]=m[4]
for k,(w,h,pf,bpp,row,n,zl) in hdr.items():
    c=chunks.get(k,{})
    try: raw=zlib.decompress(base64.b64decode(''.join(c[i] for i in sorted(c))))
    except Exception as e: print(k,'bad',e);continue
    if bpp==4:
        im=Image.frombytes('RGBA',(w,h),raw,'raw','BGRA' if pf in (80,81) else 'RGBA')
    elif bpp==1: im=Image.frombytes('L',(w,h),raw)
    elif bpp==2: im=Image.frombytes('LA',(w,h),raw)
    elif bpp==8:
        import numpy as np
        a=np.frombuffer(raw,'<f2').reshape(h,w,4).astype('f4')
        im=Image.fromarray((np.clip(a,0,1)*255).astype('u1'),'RGBA')
    else: print(k,'bpp',bpp,'pf',pf);continue
    bg=Image.new('RGBA',im.size,(128,128,128,255)); im=im.convert('RGBA'); bg.alpha_composite(im)
    bg=bg.resize((w*3,h*3),Image.NEAREST)
    fn=f'{out}/{k[0]}_{k[1]}_f{pf}_{w}x{h}.png';bg.save(fn);print(fn)
