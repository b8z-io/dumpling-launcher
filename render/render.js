// Render the jellyfish shader to PNG frames: 540x1080, 30 fps, 30 s loop + 2 s extra for the crossfade.
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const W = 540, H = 1080, FPS = 30, L = 30, C = 2, T0 = 40;
  const N = (L + C) * FPS;
  const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const p = await b.newPage({ viewport: { width: W, height: H } });
  fs.writeFileSync('r.html', fs.readFileSync('render.html', 'utf8').replace('width="W" height="H"', `width="${W}" height="${H}"`));
  await p.goto('file://' + process.cwd() + '/r.html');
  const start = Date.now();
  for (let i = 0; i < N; i++) {
    const f = `frames/f${String(i).padStart(4, '0')}.png`;
    if (fs.existsSync(f)) continue;
    const url = await p.evaluate((t) => { draw(t); return document.getElementById('c').toDataURL('image/png'); }, T0 + i / FPS);
    fs.writeFileSync(f, Buffer.from(url.split(',')[1], 'base64'));
    if (i % 60 === 0) console.log(`frame ${i}/${N}  ${((Date.now() - start) / 1000).toFixed(0)} s`);
  }
  console.log('done', N, 'frames in', ((Date.now() - start) / 1000).toFixed(0), 's');
  await b.close();
})();
