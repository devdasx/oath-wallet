"""Create the user-facing screenshot, prompt, and motion review package."""
from pathlib import Path
import json
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / 'Design/Animation-Directions'
directions = json.loads((DESIGN / 'directions.json').read_text())
subprocess.run([str(ROOT / '.build/OathAssembleDirections')], cwd=ROOT, check=True)

# A motion contact sheet keeps the same labels and geometry as the still overview.
command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-threads', '2',
           '-loop', '1', '-framerate', '24', '-i', str(DESIGN / '00-dark-overview.png')]
for item in directions:
    command += ['-threads', '1', '-i', str(DESIGN / item['folder'] / 'motion.mp4')]
filters = []
for i in range(10):
    filters.append(f'[{i+1}:v]crop=660:1434:660:0,scale=320:696:flags=lanczos,setsar=1[v{i}]')
previous = '0:v'
for i in range(10):
    x = 64 + (i % 5) * 348
    y = 212 + (i // 5) * 750
    destination = 'finished' if i == 9 else f'stage{i}'
    filters.append(f'[{previous}][v{i}]overlay={x}:{y}:shortest=1[{destination}]')
    previous = destination
command += ['-filter_complex_threads', '2', '-filter_complex', ';'.join(filters), '-map', '[finished]',
            '-an', '-t', '8', '-r', '24', '-c:v', 'libx264', '-threads', '3', '-crf', '18',
            '-preset', 'fast', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
            str(DESIGN / '00-all-directions-motion.mp4')]
subprocess.run(command, check=True)

intro = '''OATH — TEN INDEPENDENT ANIMATION DIRECTIONS

Ten separate design agents created ten native animated concepts for the Oath multichain wallet.
Open 00-all-directions.png for the light/dark comparison, or 00-all-directions-motion.mp4 to watch all ten dark-mode concepts together.

Each numbered PNG shows light mode on the left and dark mode on the right. Each phone-sized screen is rendered at 1320 x 2868 using the original 4096 x 3072 white logo. The still images show time 2.5 seconds; the videos show eight seconds of real procedural animation. Labels appear outside the app screens.

Each numbered folder contains the agent's full prompt, its design notes, and its eight-second light/dark motion preview. All-10-Agent-Prompts.txt contains all ten complete prompts in one copyable document.

These are actual Metal renderings on the Mac, not physical-phone or simulator captures. The ten shaders were also compiled and linked for iOS 17. Phone performance and interaction have not been tested. Choose the direction before integrating it into the app.

'''
intro += '\n'.join(f"{item['number']:02d} — {item['name']}" for item in directions) + '\n'
(DESIGN / 'README.txt').write_text(intro)

archive = DESIGN / 'Oath-10-Animation-Directions.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as package:
    for name in ['README.txt', 'All-10-Agent-Prompts.txt', 'directions.json', '00-all-directions.png',
                 '00-light-overview.png', '00-dark-overview.png', '00-all-directions-motion.mp4']:
        package.write(DESIGN / name, arcname=name)
    for item in directions:
        package.write(DESIGN / (item['folder'] + '.png'), arcname=item['folder'] + '.png')
        for name in ['prompt.txt', 'design-notes.txt', 'motion.mp4', 'Artwork.metal', 'Compiled.metal', 'render-checks.json']:
            path = Path(item['folder']) / name
            package.write(DESIGN / path, arcname=str(path))
with zipfile.ZipFile(archive) as package:
    assert package.testzip() is None
print(f'Review package complete: {archive.name} ({archive.stat().st_size:,} bytes)')
