import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join, extname } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const root = resolve(import.meta.dirname, process.env.FILM_ROOT || '../site');
const outRoot = resolve(import.meta.dirname, '../out');
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};
const fps = Number(option('--fps', '60'));
const scale = Number(option('--scale', '1'));
const from = Number(option('--from', '0'));
const to = Number(option('--to', '0'));
const stills = option('--stills', null);
const format = option('--format', 'landscape');
if (!['landscape', 'vertical'].includes(format)) throw new Error(`Invalid format: ${format}`);
const out = resolve(option('--out', join(outRoot,
  format === 'vertical' ? 'film-vertical.mp4' : 'film.mp4')));
if (!Number.isFinite(fps) || fps <= 0 || !Number.isFinite(scale) ||
    scale <= 0 || scale > 2 || from < 0) {
  throw new Error('Invalid frame options');
}
const mime = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript',
  '.mjs': 'text/javascript', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf', '.wav': 'audio/wav', '.json': 'application/json',
};
const server = createServer(async (request, response) => {
  try {
    const relative = decodeURIComponent(new URL(request.url, 'http://local').pathname)
      .replace(/^\/+/, '');
    const path = resolve(root, relative || 'index.html');
    if (!path.startsWith(`${root}/`) && path !== join(root, 'index.html')) {
      response.writeHead(403).end();
      return;
    }
    const bytes = await readFile(path);
    response.writeHead(200, {
      'Content-Type': mime[extname(path)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    response.end(bytes);
  } catch {
    response.writeHead(404).end('Not found');
  }
});
await new Promise((resolveListening) => server.listen(0, '127.0.0.1', resolveListening));
const port = server.address().port;
let browser;
const errors = [];

try {
  browser = await chromium.launch({
    headless: true, channel: process.env.FILM_CHANNEL || 'chromium',
    executablePath: process.env.FILM_CHROME_PATH || undefined,
    args: ['--enable-webgl', '--use-gl=angle', `--use-angle=${process.env.FILM_ANGLE || 'metal'}`,
      '--enable-unsafe-swiftshader'],
  });
  const width = Math.round((format === 'vertical' ? 1080 : 1920) * scale);
  const height = Math.round((format === 'vertical' ? 1920 : 1080) * scale);
  browser.on('disconnected', () => console.error('[browser] disconnected'));
  const page = await browser.newPage({
    viewport: { width, height }, deviceScaleFactor: 1,
  });
  page.on('console', (message) => {
    if (message.type() === 'error') {
      errors.push(message.text());
      console.error('[page console]', message.text());
    }
  });
  page.on('crash', () => console.error('[page] crashed'));
  page.on('pageerror', (error) => {
    errors.push(error.message);
    console.error('[page error]', error.message);
  });
  await page.goto(`http://127.0.0.1:${port}/?render=1${format === 'vertical' ? '&format=vertical' : ''}`, { waitUntil: 'load' });
  await page.waitForFunction(() => window.__film && window.__film.ready,
    null, { timeout: 120000 });
  await page.evaluate(() => window.__film.ready);
  const duration = await page.evaluate(() => window.__film.duration);
  console.log(`Film ready: ${duration.toFixed(2)} s; ${width}×${height}; ${fps} fps`);

  const render = async (t) => {
    await page.evaluate((time) => window.__film.renderFrame(time), t);
    return page.screenshot({ type: 'png', animations: 'disabled' });
  };
  if (stills !== null) {
    const directory = join(outRoot, format === 'vertical' ? 'stills-vertical' : 'stills');
    await mkdir(directory, { recursive: true });
    for (const raw of stills.split(',')) {
      const t = Number(raw);
      if (!Number.isFinite(t) || t < 0 || t > duration) {
        throw new Error(`Invalid still time: ${raw}`);
      }
      const png = await render(t);
      const file = join(directory, `t${t.toFixed(2).replace('.', '_')}.png`);
      await writeFile(file, png);
      console.log(`still ${t.toFixed(2)} → ${file}`);
    }
  } else {
    const end = to > 0 ? Math.min(to, duration) : duration;
    if (end <= from) throw new Error('--to must be greater than --from');
    await mkdir(resolve(out, '..'), { recursive: true });
    const wav = join(outRoot, 'master.wav');
    const base64 = await page.evaluate(() => window.__film.getMasterWav());
    await writeFile(wav, Buffer.from(base64, 'base64'));
    const ffmpeg = spawn(process.env.FFMPEG || 'ffmpeg', [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'image2pipe', '-framerate', String(fps), '-i', '-',
      '-ss', String(from), '-t', String(end - from), '-i', wav,
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '16',
      '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-movflags', '+faststart',
      '-c:a', 'aac', '-b:a', '320k', '-shortest', out,
    ], { stdio: ['pipe', 'inherit', 'inherit'] });
    let ffmpegExit;
    ffmpeg.on('exit', (code) => { ffmpegExit = code; });
    const count = Math.ceil((end - from) * fps);
    const started = Date.now();
    for (let i = 0; i < count; i++) {
      const t = from + i / fps;
      const png = await render(t);
      if (!ffmpeg.stdin.write(png)) await once(ffmpeg.stdin, 'drain');
      if (i % Math.max(1, Math.round(fps * 2)) === 0) {
        const elapsed = (Date.now() - started) / 1000;
        const eta = i ? elapsed * (count - i) / i : 0;
        console.log(`${i}/${count} frames  ·  ETA ${eta.toFixed(0)} s`);
      }
    }
    ffmpeg.stdin.end();
    await once(ffmpeg, 'close');
    if (ffmpegExit !== 0) throw new Error(`ffmpeg failed with ${ffmpegExit}`);
    console.log(`Wrote ${out}`);
  }
  if (errors.length) throw new Error(`${errors.length} page console error(s)`);
} finally {
  await browser?.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}
