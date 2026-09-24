# Keep only the listed animations in a .glb and drop the buffer data nothing
# references any more. Usage: slim_glb.py in.glb out.glb Idle Walk Run ...
import json, struct, sys

src, dst, keep = sys.argv[1], sys.argv[2], sys.argv[3:]
b = open(src, 'rb').read()
jlen = struct.unpack('<I', b[12:16])[0]
j = json.loads(b[20:20 + jlen])
bin_off = 20 + jlen + 8
binchunk = b[bin_off:bin_off + struct.unpack('<I', b[20 + jlen:24 + jlen])[0]]

def short(n):
    return n.split('|')[-1]

j['animations'] = [a for a in j.get('animations', []) if short(a['name']) in keep]
for a in j['animations']:
    a['name'] = short(a['name'])

# no textures, no need for UVs
if not j.get('textures'):
    for m in j.get('meshes', []):
        for p in m['primitives']:
            p['attributes'].pop('TEXCOORD_0', None)

# joints and weights fit in 8 bits
import numpy as np
replace = {}  # bufferView index -> new bytes
for m in j.get('meshes', []):
    for p in m['primitives']:
        for key in ('JOINTS_0', 'WEIGHTS_0'):
            ai = p['attributes'].get(key)
            if ai is None or j['accessors'][ai]['bufferView'] in replace:
                continue
            a = j['accessors'][ai]
            bv = j['bufferViews'][a['bufferView']]
            assert 'byteStride' not in bv and a.get('byteOffset', 0) == 0
            raw = binchunk[bv.get('byteOffset', 0):bv.get('byteOffset', 0) + bv['byteLength']]
            dt = {5121: np.uint8, 5123: np.uint16, 5126: np.float32}[a['componentType']]
            v = np.frombuffer(raw, dtype=dt, count=a['count'] * 4).reshape(-1, 4)
            if key == 'JOINTS_0':
                assert v.max() < 256
                out8 = v.astype(np.uint8)
            else:
                w = v.astype(np.float64) if dt == np.float32 else v / 255.0
                w = w / np.maximum(w.sum(1, keepdims=True), 1e-9)
                q = np.floor(w * 255).astype(np.int32)
                # rows must add up to 255
                q[np.arange(len(q)), w.argmax(1)] += 255 - q.sum(1)
                out8 = q.astype(np.uint8)
                a['normalized'] = True
            a['componentType'] = 5121
            a.pop('min', None); a.pop('max', None)
            replace[a['bufferView']] = out8.tobytes()

# every accessor still in use
used = set()
def mark(i):
    if i is not None:
        used.add(i)
for m in j.get('meshes', []):
    for p in m['primitives']:
        for v in p['attributes'].values():
            mark(v)
        mark(p.get('indices'))
        for t in p.get('targets', []):
            for v in t.values():
                mark(v)
for s in j.get('skins', []):
    mark(s.get('inverseBindMatrices'))
for a in j['animations']:
    for sm in a['samplers']:
        mark(sm['input']); mark(sm['output'])

old_acc = j['accessors']
acc_map, new_acc = {}, []
for i, a in enumerate(old_acc):
    if i in used:
        acc_map[i] = len(new_acc)
        new_acc.append(a)

used_bv = {a['bufferView'] for a in new_acc if 'bufferView' in a}
used_bv |= {im['bufferView'] for im in j.get('images', []) if 'bufferView' in im}
bv_map, new_bv, out = {}, [], bytearray()
for i, bv in enumerate(j['bufferViews']):
    if i not in used_bv:
        continue
    while len(out) % 4:
        out.append(0)
    data = replace.get(i) or binchunk[bv.get('byteOffset', 0):bv.get('byteOffset', 0) + bv['byteLength']]
    nbv = dict(bv, byteOffset=len(out), byteLength=len(data))
    out += data
    bv_map[i] = len(new_bv)
    new_bv.append(nbv)

for a in new_acc:
    if 'bufferView' in a:
        a['bufferView'] = bv_map[a['bufferView']]
for im in j.get('images', []):
    if 'bufferView' in im:
        im['bufferView'] = bv_map[im['bufferView']]
def remap(i):
    return acc_map[i] if i is not None else None
for m in j.get('meshes', []):
    for p in m['primitives']:
        p['attributes'] = {k: remap(v) for k, v in p['attributes'].items()}
        if 'indices' in p:
            p['indices'] = remap(p['indices'])
        if 'targets' in p:
            p['targets'] = [{k: remap(v) for k, v in t.items()} for t in p['targets']]
for s in j.get('skins', []):
    if 'inverseBindMatrices' in s:
        s['inverseBindMatrices'] = remap(s['inverseBindMatrices'])
for a in j['animations']:
    for sm in a['samplers']:
        sm['input'] = remap(sm['input']); sm['output'] = remap(sm['output'])

j['accessors'] = new_acc
j['bufferViews'] = new_bv
while len(out) % 4:
    out.append(0)
j['buffers'] = [{'byteLength': len(out)}]
js = json.dumps(j, separators=(',', ':')).encode()
while len(js) % 4:
    js += b' '
total = 12 + 8 + len(js) + 8 + len(out)
with open(dst, 'wb') as f:
    f.write(struct.pack('<III', 0x46546C67, 2, total))
    f.write(struct.pack('<II', len(js), 0x4E4F534A)); f.write(js)
    f.write(struct.pack('<II', len(out), 0x004E4942)); f.write(out)
print(f"{src} {len(b)//1024}KB -> {dst} {total//1024}KB, anims: {[a['name'] for a in j['animations']]}")
