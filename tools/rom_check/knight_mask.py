import sys; sys.path.insert(0,'tools')
import numpy as np
from collections import deque
from samdisk import read_files, screen
from PIL import Image
F=read_files(sys.argv[1])
SP,PAL=screen(F['HB SP'])
T = np.array([[int(c, 16) for c in r] for r in ['33233333','22222232','22222232','22222332','33333323','22322222','22322222','23322222']])

def flood(start_mask, passable):
    """pixels reachable from start_mask through passable (4-connected)"""
    h,w=passable.shape; seen=start_mask&passable; q=deque(zip(*np.nonzero(seen)))
    while q:
        y,x=q.popleft()
        for yy,xx in ((y+1,x),(y-1,x),(y,x+1),(y,x-1)):
            if 0<=yy<h and 0<=xx<w and passable[yy,xx] and not seen[yy,xx]:
                seen[yy,xx]=True; q.append((yy,xx))
    return seen

def new_mask(cell):
    h,w=cell.shape
    # brick phase of this cell (fit on its blue pixels)
    best=None
    for dy in range(8):
        for dx in range(8):
            exp=np.array([[T[(y+dy)&7][(x+dx)&7] for x in range(w)] for y in range(h)])
            sc=(cell==exp)[np.isin(cell,[2,3])].mean()
            if best is None or sc>best[0]: best=(sc,exp)
    exp=best[1]
    edge=np.zeros((h,w),bool); edge[0,:]=edge[-1,:]=edge[:,0]=edge[:,-1]=True
    sky=flood(edge&(cell==0), cell==0)               # black joined to the edge
    def dil(m):
        p=np.pad(m,1); g=p.copy()
        for dy in (-1,0,1):
            for dx in (-1,0,1): g|=np.roll(np.roll(p,dy,0),dx,1)
        return g[1:-1,1:-1]
    # teal is mortar only where the brick pattern has mortar and there are bricks
    # round it (not up against the sky, where his teal is just his)
    mortar=(cell==3)&(exp==3)&dil(dil(cell==2))
    bg=(cell==2)|sky|mortar
    him=~flood(edge, bg)                             # enclosed background is his
    # mortar-coloured gaps with him on both sides (left/right or above/below) are his
    p=np.pad(him,1)
    l,r,u,d=p[1:-1,:-2],p[1:-1,2:],p[:-2,1:-1],p[2:,1:-1]
    him|=(cell==3)&((l&r)|(u&d))
    # drop specks: keep 8-connected pieces of 5 pixels or more
    lab=np.zeros(him.shape,int); n=0
    for y0,x0 in zip(*np.nonzero(him)):
        if lab[y0,x0]: continue
        n+=1; q=deque([(y0,x0)]); lab[y0,x0]=n; comp=[(y0,x0)]
        while q:
            y,x=q.popleft()
            for yy in (y-1,y,y+1):
                for xx in (x-1,x,x+1):
                    if 0<=yy<h and 0<=xx<w and him[yy,xx] and not lab[yy,xx]:
                        lab[yy,xx]=n; q.append((yy,xx)); comp.append((yy,xx))
        if len(comp)<5:
            for y,x in comp: him[y,x]=False
    return him

def old_mask(cell):
    def grow8(m):
        p=np.pad(m,1); g=p.copy()
        for dy in (-1,0,1):
            for dx in (-1,0,1): g|=np.roll(np.roll(p,dy,0),dx,1)
        return g[1:-1,1:-1]
    core=np.isin(cell,[15,11,5,4,7]); reg=grow8(grow8(core))
    op=reg&np.isin(cell,[15,11,5,4,7,3,0])
    edge=np.zeros(cell.shape,bool); edge[0,:]=edge[-1,:]=edge[:,0]=edge[:,-1]=True
    op&=~flood(edge&(cell==0),cell==0)
    return op

if __name__=='__main__':
    def clut(v):
        br=(v>>3)&1; f=lambda hi,lo: min(255,((hi<<1)|lo)*73+br*36)
        return (f((v>>5)&1,(v>>1)&1), f((v>>6)&1,(v>>2)&1), f((v>>4)&1,v&1))
    pal=np.array([clut(v) for v in PAL],np.uint8)
    rows=[]
    for k in range(4):
        cell=SP[1:23,169+17*k:185+17*k]
        tiles=[]
        for m in (old_mask(cell),new_mask(cell)):
            im=np.zeros((22,16,3),np.uint8); im[:]=(255,0,255)
            im[m]=pal[cell][m]
            tiles.append(im)
        tiles.insert(0,pal[cell])
        rows.append(np.concatenate([np.pad(t,((1,1),(1,1),(0,0))) for t in tiles],1))
    Image.fromarray(np.concatenate(rows,0)).resize((54*12,96*12),Image.NEAREST).save('kmask.png')
