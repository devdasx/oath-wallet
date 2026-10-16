"""Compile all independent motion concepts for iOS and verify their deliverables."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / 'Design/Animation-Directions'
OUTPUT = ROOT / 'Validation/animation-directions'
OUTPUT.mkdir(parents=True, exist_ok=True)
directions = json.loads((DESIGN / 'directions.json').read_text())
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
metal = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--find', 'metal'], text=True).strip()
metallib = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--find', 'metallib'], text=True).strip()


def validate(item):
    folder = DESIGN / item['folder']
    required = ['Artwork.metal', 'Compiled.metal', 'prompt.txt', 'design-notes.txt',
                'light.png', 'dark.png', 'light-still.png', 'dark-still.png', 'motion.mp4', 'render-checks.json']
    for name in required:
        assert (folder / name).is_file(), f"Missing {folder.name}/{name}"
    dimensions = {}
    for name in ['light.png', 'dark.png', 'light-still.png', 'dark-still.png']:
        data = (folder / name).read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        size = struct.unpack('>II', data[16:24])
        assert size == (1320, 2868), f'{folder.name}: wrong native dimensions'
        dimensions[name] = list(size)
    checks = json.loads((folder / 'render-checks.json').read_text())
    assert checks['metal_compilation'] == 'passed'
    assert len(checks['checks']) == 2
    assert all(mode['opaque'] and mode['lower_quarter_range'] <= 2 and mode['moving_art_channels'] > 0
               for mode in checks['checks'])
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
        'stream=width,height,nb_frames,codec_name:format=duration', '-of', 'json', str(folder / 'motion.mp4')
    ], text=True))
    stream = probe['streams'][0]
    assert (stream['width'], stream['height']) == (1320, 1434)
    assert int(stream['nb_frames']) == 192
    assert abs(float(probe['format']['duration']) - 8) < 0.05
    air = OUTPUT / (folder.name + '.air')
    library = OUTPUT / (folder.name + '.metallib')
    commands = [
        [metal, '-c', '-target', 'air64-apple-ios17.0', '-isysroot', sdk,
         str(folder / 'Compiled.metal'), '-o', str(air)],
        [metallib, str(air), '-o', str(library)]
    ]
    diagnostics = []
    for command in commands:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        diagnostics.append(result.stdout)
        assert result.returncode == 0, f"{folder.name}: iOS shader build failed\n{result.stdout}"
    (OUTPUT / (folder.name + '.log')).write_text('\n'.join(diagnostics))
    return {
        **item, 'ios_metal_compile_and_link': 'passed', 'native_pngs': dimensions,
        'motion_seconds': 8, 'motion_frames': 192, 'render_checks': checks,
        'artwork_sha256': hashlib.sha256((folder / 'Artwork.metal').read_bytes()).hexdigest(),
        'prompt_words': len((folder / 'prompt.txt').read_text().split())
    }


with ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(validate, directions))
assert len(results) == 10
assert len({item['artwork_sha256'] for item in results}) == 10
report = {
    'concepts': 10, 'separate_design_agents': 10,
    'source': 'Native Metal motion studies rendered on the Mac GPU',
    'main_app_selection': 'Unchanged until the user chooses a direction',
    'physical_device': 'not used', 'simulator': 'not used', 'directions': results
}
(OUTPUT / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS: ten distinct shaders compiled and linked for iOS 17; native PNGs and eight-second videos verified.')
