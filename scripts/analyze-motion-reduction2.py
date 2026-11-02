#!/usr/bin/env python3
"""Probe factor-two motion reduction using native graph residual-blur parameters.

Fits symmetric coefficients to four radius-three impulse phases, then reports
all 48 scanlines at each of eight radii without refitting. Residual parameters
come from native graph descriptions: this is not a standalone renderer or an
acceptance gate for angular motion. Requires NumPy.
"""
import argparse
import base64
import hashlib
import json
import re
from pathlib import Path
import numpy as np

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture',type=Path)
parser.add_argument('--reduction4-report',type=Path,required=True)
parser.add_argument('--report',type=Path,required=True)
args=parser.parse_args()
capture=args.capture
data=json.loads(capture.read_text())
assert (data['schema'],data['sourceWidth'],data['sourceHeight'],data['scanlineY'])==(1,512,8,3)
width=data['sourceWidth']
def decode(item):
    raw=base64.b64decode(item['floatBase64'],validate=True)
    assert hashlib.sha256(raw).hexdigest()==item['floatSha256']
    values=np.frombuffer(raw,dtype='<f4').reshape(width,4)
    assert np.isfinite(values).all()
    return values[:,0].astype(np.float64)
inputs={(c['fixture'],c['phase']):decode(c['output']) for c in data['inputs']}
expected_keys={(fixture,phase) for fixture in ['impulse','step','stripes'] for phase in range(16)}
assert len(data['inputs'])==48 and set(inputs)==expected_keys
targets={(c['radius'],c['fixture'],c['phase']):c for c in data['cases'] if c['filter']=='CIMotionBlur'}
report=json.loads(args.reduction4_report.read_text())
assert report['captureSHA256']==hashlib.sha256(capture.read_bytes()).hexdigest()
model=next(m for m in report['models'] if m['reach']==10 and m['quantizedTextureFractions'])
offset4=np.array([a for a,b,v in model['tapPairs']]+[b for a,b,v in model['tapPairs']])
weights4=np.array([v for a,b,v in model['tapPairs']]*2)
assert np.isfinite(weights4).all() and weights4.min()>=0 and weights4.sum()>0
weights4/=weights4.sum()

def residual(radius):
    description=targets[(radius,'impulse',0)]['output']['description']
    if '_gaussianBlur3(' in description:
        offset=float(re.search(r'offset0=\[([^ ]+)',description).group(1))
        assert np.isfinite(offset) and 0<=offset<=1
        return np.array([-offset,offset]),np.array([.5,.5])
    match=re.search(r'_gaussianBlur7\(src,offset01=\[([^]]+)\],weight=\[([^]]+)\]',description)
    assert match is not None,description
    coordinates=list(map(float,match.group(1).split()))
    weights=list(map(float,match.group(2).split()))
    assert len(coordinates)==4 and coordinates[1]==coordinates[3]==0
    assert len(weights)==2 and np.isfinite(coordinates+weights).all()
    return np.array([-coordinates[0],coordinates[0],-coordinates[2],coordinates[2]]),np.repeat(weights,2)

def forward(source, stages, gaussian, half=False):
    def reduced(indices,level):
        if level==0: return source[np.clip(indices,0,width-1)]
        factor,offsets,weights=stages[level-1]
        unique,inverse=np.unique(indices,return_inverse=True)
        previous=unique[:,None]*factor+offsets[None,:]
        result=np.sum(reduced(previous,level-1)*weights[None,:],axis=1)
        if half: result=result.astype(np.float16).astype(np.float64)
        return result[inverse].reshape(indices.shape)
    def filtered(indices):
        offsets,weights=gaussian
        result=np.zeros(indices.shape)
        for offset,weight in zip(offsets,weights):
            position=indices+offset
            lo=np.floor(position).astype(int)
            t=np.floor((position-lo)*256+.5)/256
            result+=weight*((1-t)*reduced(lo,len(stages))+t*reduced(lo+1,len(stages)))
        if half: result=result.astype(np.float16).astype(np.float64)
        return result
    scale=np.prod([s[0] for s in stages])
    q=(np.arange(width)+.5)/scale-.5
    lo=np.floor(q).astype(int)
    t=q-lo
    w=np.array([(1-t)**3/6,(3*t**3-6*t*t+4)/6,(-3*t**3+3*t*t+3*t+1)/6,t**3/6])
    result=np.zeros(width)
    for pair,shift in [(0,-1),(2,1)]:
        g=w[pair]+w[pair+1]
        position=lo+shift+w[pair+1]/g
        index=np.floor(position).astype(int)
        t=np.floor((position-index)*256+.5)/256
        result+=g*((1-t)*filtered(index)+t*filtered(index+1))
    return result

models=[]
gaussian=residual(3)
for reach in [4,5,6,8,10]:
    pairs=[(t,1-t) for t in range(1-reach,1)]
    offsets=np.array([a for a,b in pairs]+[b for a,b in pairs])
    matrix=[]
    target=[]
    for phase in range(4):
        source=inputs[('impulse',phase)]
        columns=[]
        for i in range(reach):
            weights=np.zeros(reach*2); weights[i]=weights[i+reach]=1
            columns.append(forward(source,[(2,offsets,weights)],gaussian))
        matrix.append(np.array(columns).T)
        target.append(decode(targets[(3,'impulse',phase)]['output']))
    taps,_,rank,_=np.linalg.lstsq(np.concatenate(matrix),np.concatenate(target),rcond=None)
    weights=np.tile(taps,2); weights/=weights.sum()
    rows=[]
    for radius in [3,3.05,3.25,9.25,9.5,10,10.103629710818451,12]:
        stages=[(2,offsets,weights)] if radius<4 else [(4,offset4,weights4),(2,offsets,weights)]
        for half in [False,True]:
            checks=[]
            for (fixture,phase),source in inputs.items():
                native=targets[(radius,fixture,phase)]['output']
                expected=decode(native)
                actual=forward(source,stages,residual(radius),half)
                raw=base64.b64decode(native['rgbaBase64'],validate=True)
                assert hashlib.sha256(raw).hexdigest()==native['byteSha256']
                byte=np.frombuffer(raw,dtype='u1').reshape(width,4)[:,0]
                actual_byte=np.clip(np.floor(actual*255+.5),0,255)
                delta=np.abs(actual-expected)*255
                checks.append({'fixture':fixture,'phase':phase,'maxFloatByteError':float(delta.max()),
                               'interiorFloatByteError':float(delta[48:-48].max()),
                               'maxByteError':int(np.abs(actual_byte-byte).max())})
            rows.append({'radius':radius,'halfIntermediates':half,'checks':checks,
                         'withinOneByte':sum(c['maxByteError']<=1 for c in checks),
                         'maxByteError':max(c['maxByteError'] for c in checks)})
    models.append({'reach':reach,'rank':int(rank),'tapPairs':[[a,b,float(v)] for (a,b),v in zip(pairs,taps)],'rows':rows})
    print('REDUCE2',reach,'rank',rank,'minimum',float(taps.min()))
    for row in rows:
        print(row['radius'],row['halfIntermediates'],row['withinOneByte'],row['maxByteError'])
out={'captureSHA256':hashlib.sha256(capture.read_bytes()).hexdigest(),
     'scope':'Diagnostic fitting on radius-three impulse phases; held-out radii use their native graph parameters',
     'reduction4ReportSHA256':hashlib.sha256(args.reduction4_report.read_bytes()).hexdigest(),'models':models}
args.report.write_text(json.dumps(out,indent=2)+'\n')
