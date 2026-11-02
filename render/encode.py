# Crossfade the last 2 s of the render into the first 2 s so the 30 s loop is seamless, then encode H.264.
import os, subprocess, sys
from PIL import Image
FPS, L, C = 30, 30, 2
N, Cn = L * FPS, C * FPS
os.makedirs('out', exist_ok=True)
for i in range(N):
    a = Image.open(f'frames/f{i:04d}.png').convert('RGB')
    if i < Cn:   # the loop's start fades in from the frames just after its end
        b = Image.open(f'frames/f{N + i:04d}.png').convert('RGB')
        a = Image.blend(b, a, i / Cn)
    a.save(f'out/o{i:04d}.png', compress_level=1)
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', str(FPS), '-i', 'out/o%04d.png',
                '-c:v', 'libx264', '-preset', 'slow', '-crf', '21', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
                '-level', '4.1', '-g', '60', '-movflags', '+faststart', '-an', 'jellyfish-loop.mp4'], check=True)
print('encoded', os.path.getsize('jellyfish-loop.mp4') // 1024, 'KB')
