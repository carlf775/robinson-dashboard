import tailwindcss from '@tailwindcss/vite';
import path from "path";
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import type { Plugin } from 'vite';

function datasetStatsPlugin(): Plugin {
  const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  function ulidToMs(ulid: string): number {
    let ms = 0;
    for (const c of ulid.slice(0, 10)) ms = ms * 32 + CROCKFORD.indexOf(c.toUpperCase());
    return ms;
  }

  return {
    name: 'dataset-stats',
    configureServer(server) {
      server.middlewares.use('/api/dataset-stats', async (_req, res) => {
        try {
          const fs = await import('fs');
          const path = await import('path');
          const os = await import('os');
          const csvPath = path.default.join(os.default.homedir(), 'Downloads', 'avkplast_inference_results.csv');

          const csvLines = fs.default.existsSync(csvPath)
            ? fs.default.readFileSync(csvPath, 'utf8').trim().split('\n')
            : [];
          const headers = csvLines[0]?.split(',') ?? [];
          const rows = csvLines.slice(1).map(l => {
            const v = l.split(',');
            return Object.fromEntries(headers.map((h, i) => [h, v[i] ?? '']));
          }).filter(r => !r.error);

          let total = 0, defects = 0, pass = 0;
          let crown = 0, thread = 0, cavity = 0, underfill = 0;
          const hourlyTotal: Record<number, number> = {};
          const hourlyDefect: Record<number, number> = {};

          for (const r of rows) {
            total++;
            const isDefect = parseInt(r.defect_detected ?? '0') === 1;
            if (isDefect) defects++; else pass++;
            crown    += parseInt(r.crown ?? '0');
            thread   += parseInt(r.thread ?? '0');
            cavity   += parseInt(r.cavity_markers ?? '0');
            underfill+= parseInt(r.underfilling ?? '0');
            const key = r.path?.split('/').pop()?.replace('.png', '');
            if (key) {
              const ms = ulidToMs(key);
              const hour = new Date(ms).getUTCHours();
              hourlyTotal[hour] = (hourlyTotal[hour] ?? 0) + 1;
              if (isDefect) hourlyDefect[hour] = (hourlyDefect[hour] ?? 0) + 1;
            }
          }

          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({
            total: 5036,
            processed: total,
            defects, pass,
            defectPct: total > 0 ? (defects / total * 100).toFixed(1) : '0',
            passPct:   total > 0 ? (pass   / total * 100).toFixed(1) : '0',
            classes: { crown, thread, cavity_markers: cavity, underfilling: underfill },
            hourly: Array.from({length: 24}, (_, h) => ({
              hour: h,
              total: hourlyTotal[h] ?? 0,
              defects: hourlyDefect[h] ?? 0,
            })),
            date: '2026-01-14',
          }));
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: msg }));
        }
      });
    },
  };
}

function sam3Plugin(): Plugin {
  const ROBOFLOW_URL = 'https://avk-test11.roboflow.cloud';
  const API_KEY = 'CWwwUoMmPO4NWg63XFhU';
  const MODEL_ID = 'avk-ring/15';
  const PROMPTS = [
    { type: 'text', text: 'crown' },
    { type: 'text', text: 'thread' },
    { type: 'text', text: 'cavity_markers' },
    { type: 'text', text: 'underfilling' },
  ];

  return {
    name: 'sam3-api',
    configureServer(server) {
      server.middlewares.use('/api/sam3/infer', async (req, res) => {
        if (req.method !== 'POST') { res.writeHead(405); res.end(); return; }
        const chunks: Buffer[] = [];
        req.on('data', (c: Buffer) => chunks.push(c));
        req.on('end', async () => {
          try {
            const { image } = JSON.parse(Buffer.concat(chunks).toString());
            // Strip data URL prefix if present
            const b64 = image.replace(/^data:image\/[a-z]+;base64,/, '');

            const rfRes = await fetch(`${ROBOFLOW_URL}/sam3/concept_segment?api_key=${API_KEY}`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                model_id: MODEL_ID,
                image: { type: 'base64', value: b64 },
                prompts: PROMPTS,
                output_prob_thresh: 0.3,
                format: 'polygon',
              }),
            });
            const data = await rfRes.json() as Record<string, unknown>;
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(data));
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: msg }));
          }
        });
      });
    },
  };
}

function emailPlugin(): Plugin {
  return {
    name: 'email-api',
    configureServer(server) {
      server.middlewares.use('/api/send-email', async (req, res) => {
        if (req.method !== 'POST') {
          res.writeHead(405); res.end(); return;
        }
        const chunks: Buffer[] = [];
        req.on('data', (c: Buffer) => chunks.push(c));
        req.on('end', async () => {
          try {
            const { to, subject, body } = JSON.parse(Buffer.concat(chunks).toString());
            const nodemailer = await import('nodemailer');
            const transporter = nodemailer.default.createTransport({
              host: process.env.SMTP_HOST ?? 'smtp.gmail.com',
              port: parseInt(process.env.SMTP_PORT ?? '587'),
              secure: process.env.SMTP_SECURE === 'true',
              auth: {
                user: process.env.SMTP_USER,
                pass: process.env.SMTP_PASS,
              },
            });
            await transporter.sendMail({
              from: process.env.SMTP_FROM ?? process.env.SMTP_USER,
              to,
              subject,
              text: body,
              html: `<pre style="font-family:monospace;white-space:pre-wrap">${body}</pre>`,
            });
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: true }));
          } catch (err: unknown) {
            const msg = err instanceof Error ? err.message : String(err);
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: false, error: msg }));
          }
        });
      });
    },
  };
}

function datasetImagePlugin(): Plugin {
  return {
    name: 'dataset-image',
    configureServer(server) {
      // Serve raw images from ~/Downloads/avkplast_parts/
      server.middlewares.use('/api/dataset-image', async (req, res) => {
        try {
          const fs = await import('fs');
          const pathMod = await import('path');
          const os = await import('os');
          const url = new URL(req.url ?? '', 'http://localhost');
          const relPath = url.searchParams.get('path') ?? '';
          if (!relPath) { res.writeHead(400); res.end('Missing path'); return; }
          const abs = pathMod.default.join(os.default.homedir(), 'Downloads', relPath);
          if (!fs.default.existsSync(abs)) { res.writeHead(404); res.end('Not found'); return; }
          const data = fs.default.readFileSync(abs);
          res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public,max-age=86400' });
          res.end(data);
        } catch (err: unknown) {
          res.writeHead(500); res.end(String(err));
        }
      });
      // Serve annotated images from ~/Downloads/avkplast_annotated/
      server.middlewares.use('/api/annotated-image', async (req, res) => {
        try {
          const fs = await import('fs');
          const pathMod = await import('path');
          const os = await import('os');
          const url = new URL(req.url ?? '', 'http://localhost');
          const key = url.searchParams.get('key') ?? '';
          if (!key) { res.writeHead(400); res.end('Missing key'); return; }
          const abs = pathMod.default.join(os.default.homedir(), 'Downloads', 'avkplast_annotated', key + '.jpg');
          if (!fs.default.existsSync(abs)) { res.writeHead(404); res.end('Not found'); return; }
          const data = fs.default.readFileSync(abs);
          res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'no-cache' });
          res.end(data);
        } catch (err: unknown) {
          res.writeHead(500); res.end(String(err));
        }
      });
      // Serve AD composite images from ~/Downloads/avkplast_ad_annotated/
      server.middlewares.use('/api/ad-image', async (req, res) => {
        try {
          const fs = await import('fs');
          const pathMod = await import('path');
          const os = await import('os');
          const url = new URL(req.url ?? '', 'http://localhost');
          const key = url.searchParams.get('key') ?? '';
          if (!key) { res.writeHead(400); res.end('Missing key'); return; }
          const abs = pathMod.default.join(os.default.homedir(), 'Downloads', 'avkplast_ad_annotated', key + '.jpg');
          if (!fs.default.existsSync(abs)) { res.writeHead(404); res.end('Not found'); return; }
          const data = fs.default.readFileSync(abs);
          res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'public,max-age=86400' });
          res.end(data);
        } catch (err: unknown) {
          res.writeHead(500); res.end(String(err));
        }
      });
    },
  };
}

// https://vite.dev/config/
export default defineConfig({
  base: process.env.NODE_ENV === 'production' ? '/robinson-dashboard/' : '/',
  plugins: [tailwindcss(), svelte(), emailPlugin(), sam3Plugin(), datasetStatsPlugin(), datasetImagePlugin()],
  publicDir: 'static',
  resolve: {
    alias: {
      $lib: path.resolve("./src/lib"),
      $nodes: path.resolve("./nodes"),
    },
    // Force all shared deps to resolve from ui/node_modules so files
    // outside the project root (src/nodes/*/ui/) find them correctly.
    dedupe: ['svelte', '@lucide/svelte', '@xyflow/svelte'],
  },
  server: {
    proxy: {
      '/api': 'http://localhost:8080',
      '/ws': { target: 'ws://localhost:8080', ws: true },
    },
    fs: {
      allow: ['..'],
    },
  },
});

