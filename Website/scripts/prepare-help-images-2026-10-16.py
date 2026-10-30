"""Convert genuine simulator captures; do not draw, crop or invent app UI."""
from pathlib import Path
from PIL import Image
import json,hashlib,shutil,datetime
root=Path(__file__).resolve().parents[1];shots=Path('/tmp/oath-help-raw/iPhone')
w=json.loads((root/'src/help/walkthroughs.json').read_text());names=sorted({x['image'] for items in w.values() for x in items})
out=root/'public/help/assets';raw=root/'Reports/help-update-2026-10-16/raw';raw.mkdir(parents=True,exist_ok=True)
manifest=[];missing=[]
for name in names:
 mode=name.removeprefix('guide-');source=shots/(('wc-crossSwap' if mode=='wc-crossswap' else mode)+'.png')
 if not source.exists():missing.append(mode);continue
 target=out/(name+'.webp');image=Image.open(source);assert image.size==(1320,2868),(mode,image.size)
 image.convert('RGB').save(target,'WEBP',quality=92,method=6)
 shutil.copy2(source,raw/(name+'.png'))
 manifest.append(dict(image=name,source_mode=source.stem,width=image.width,height=image.height,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),webp_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),webp_bytes=target.stat().st_size,captured_at=datetime.datetime.fromtimestamp(source.stat().st_mtime,datetime.timezone.utc).isoformat(),device='iPhone 18 Pro Max simulator',os='iOS 27',data='Synthetic local balances/history and offline unsigned request fixtures',live_funds_sent=False,secrets_displayed=False))
(root/'Reports/help-update-2026-10-16/screenshots.json').write_text(json.dumps(dict(captures=manifest,missing=missing,method='Real SwiftUI app views in a disposable source copy. PNGs preserved unchanged; WebP encoding only; no generated UI or compositing.'),indent=2)+'\n')
print('Prepared',len(manifest),'screenshots; missing:',', '.join(missing))
