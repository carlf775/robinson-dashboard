<script lang="ts">
  import { onMount } from 'svelte';
  import DatabaseIcon from '@lucide/svelte/icons/database';
  import ActivityIcon from '@lucide/svelte/icons/activity';
  import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
  import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
  import ShieldAlertIcon from '@lucide/svelte/icons/shield-alert';

  // ── Sub-tab ────────────────────────────────────────────────────────────────
  let activeSubTab = $state<'ad' | 'raw'>('ad');

  // ── Data types ─────────────────────────────────────────────────────────────
  type Sample = { key: string; anomalous: boolean; score: number };

  let samples    = $state<Sample[]>([]);
  let loading    = $state(true);
  let errorMsg   = $state('');

  let lightboxSample = $state<Sample | null>(null);

  const THRESHOLD = 0.5; // anomaly score threshold

  function navigateAd(dir: 1 | -1) {
    if (!lightboxSample) return;
    const list = filteredSamples;
    const idx = list.indexOf(lightboxSample);
    if (idx === -1) return;
    lightboxSample = list[(idx + dir + list.length) % list.length];
  }
  function navigateRaw(dir: 1 | -1) {
    if (!lightboxSample) return;
    const idx = samples.indexOf(lightboxSample);
    if (idx === -1) return;
    lightboxSample = samples[(idx + dir + samples.length) % samples.length];
  }

  function onKeydown(e: KeyboardEvent) {
    if (!lightboxSample) return;
    if (e.key === 'ArrowRight') { e.preventDefault(); activeSubTab === 'raw' ? navigateRaw(1) : navigateAd(1); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); activeSubTab === 'raw' ? navigateRaw(-1) : navigateAd(-1); }
    else if (e.key === 'Escape') lightboxSample = null;
  }

  async function loadData() {
    loading = true; errorMsg = '';
    try {
      const r = await fetch(import.meta.env.BASE_URL + 'robinson_samples.json');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      samples = await r.json();
    } catch (e) {
      errorMsg = e instanceof Error ? e.message : 'Failed to load data';
    } finally { loading = false; }
  }

  onMount(() => {
    loadData();
    window.addEventListener('keydown', onKeydown);
    return () => window.removeEventListener('keydown', onKeydown);
  });

  // ── Chart helpers ──────────────────────────────────────────────────────────
  const W = 560; const H = 120;
  const PAD = { t: 10, r: 8, b: 28, l: 44 };
  const cw = W - PAD.l - PAD.r;
  const ch = H - PAD.t - PAD.b;

  function smoothPath(pts: number[][]): string {
    if (pts.length < 2) return '';
    let d = `M${pts[0][0].toFixed(2)},${pts[0][1].toFixed(2)}`;
    for (let i = 1; i < pts.length; i++) {
      const p0 = pts[i - 2] ?? pts[i - 1];
      const p1 = pts[i - 1];
      const p2 = pts[i];
      const p3 = pts[i + 1] ?? p2;
      const cp1x = p1[0] + (p2[0] - p0[0]) / 6;
      const cp1y = p1[1] + (p2[1] - p0[1]) / 6;
      const cp2x = p2[0] - (p3[0] - p1[0]) / 6;
      const cp2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += ` C${cp1x.toFixed(2)},${cp1y.toFixed(2)} ${cp2x.toFixed(2)},${cp2y.toFixed(2)} ${p2[0].toFixed(2)},${p2[1].toFixed(2)}`;
    }
    return d;
  }
  function smoothFillPath(pts: number[][], baseline: number): string {
    if (pts.length < 2) return '';
    return `${smoothPath(pts)} L${pts[pts.length-1][0].toFixed(2)},${baseline.toFixed(2)} L${pts[0][0].toFixed(2)},${baseline.toFixed(2)} Z`;
  }
  function fmtNum(n: number) { return n.toLocaleString(); }

  // ── Derived stats ──────────────────────────────────────────────────────────
  const total      = $derived(samples.length);
  const anomCount  = $derived(samples.filter(s => s.anomalous).length);
  const goodCount  = $derived(samples.filter(s => !s.anomalous).length);
  const anomPct    = $derived(total > 0 ? (anomCount / total * 100).toFixed(1) : '0.0');
  const goodPct    = $derived(total > 0 ? (goodCount / total * 100).toFixed(1) : '0.0');

  // Score histogram: 20 buckets from 0→1
  const BUCKETS = 20;
  const scoreDist = $derived(() => {
    const bins = Array(BUCKETS).fill(0);
    for (const s of samples) {
      const idx = Math.min(Math.floor(s.score * BUCKETS), BUCKETS - 1);
      bins[idx]++;
    }
    return bins;
  });
  const scoreMax = $derived(Math.max(...scoreDist(), 1));
  const threshX  = $derived(PAD.l + THRESHOLD * cw);

  // Gallery filter state
  let galleryFilter = $state<'all' | 'anomaly' | 'good'>('all');

  const filteredSamples = $derived(
    galleryFilter === 'all' ? samples :
    galleryFilter === 'anomaly' ? samples.filter(s => s.anomalous) :
    samples.filter(s => !s.anomalous)
  );

  // Score distribution line for smoothed overlay
  const scoreLinePts = $derived(
    scoreDist().map((v, i) => [
      PAD.l + (i / (BUCKETS - 1)) * cw,
      PAD.t + ch - (v / scoreMax) * ch,
    ])
  );
</script>

<!-- Lightbox -->
{#if lightboxSample}
  {@const list = activeSubTab === 'raw' ? samples : filteredSamples}
  {@const lbIdx = list.indexOf(lightboxSample)}
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div class="lightbox" onclick={() => lightboxSample = null} role="dialog" aria-modal="true">
    <button class="lb-nav lb-nav-prev" onclick={(e) => { e.stopPropagation(); activeSubTab === 'raw' ? navigateRaw(-1) : navigateAd(-1); }} aria-label="Previous">&#8592;</button>
    <div class="lb-inner" onclick={(e) => e.stopPropagation()}>
      <img src="{import.meta.env.BASE_URL}images/{lightboxSample.key}.jpg" alt={lightboxSample.key} class="lb-img"/>
      <div class="lb-info">
        <div class="lb-key">{lightboxSample.key} <span class="lb-counter">{lbIdx + 1} / {list.length}</span></div>
        <div class="lb-tags">
          <span class="lb-status {lightboxSample.anomalous ? 'lb-defect' : 'lb-pass'}">
            {lightboxSample.anomalous ? 'ANOMALY' : 'GOOD'}
          </span>
          <span class="lb-tag" style="color:{lightboxSample.score >= THRESHOLD ? '#e57373' : '#70c1a3'}">Score: {lightboxSample.score.toFixed(4)}</span>
          <span class="lb-tag" style="color:#555">threshold {lightboxSample.score >= THRESHOLD ? '↑' : '↓'} {THRESHOLD}</span>
        </div>
        <div class="lb-hint">← → to navigate · Esc to close</div>
      </div>
    </div>
    <button class="lb-nav lb-nav-next" onclick={(e) => { e.stopPropagation(); activeSubTab === 'raw' ? navigateRaw(1) : navigateAd(1); }} aria-label="Next">&#8594;</button>
  </div>
{/if}

<div class="wrap">
  <!-- Header -->
  <div class="header">
    <div class="header-left">
      <DatabaseIcon class="size-4" style="color:#70c1a3" />
      <div>
        <h1 class="title">Real Dataset — Robinson Vision V1</h1>
        <p class="subtitle">~2.85M real images from S3 · 50 samples shown</p>
      </div>
    </div>

    <!-- Sub-tabs -->
    <div class="subtabs">
      <button class="subtab {activeSubTab === 'ad' ? 'subtab-active' : ''}" onclick={() => activeSubTab = 'ad'}>
        <ActivityIcon class="size-3.5" />
        AD Model · robinson
      </button>
      <button class="subtab {activeSubTab === 'raw' ? 'subtab-active' : ''}" onclick={() => activeSubTab = 'raw'}>
        <DatabaseIcon class="size-3.5" />
        All Images
      </button>
    </div>

    <button class="btn-icon" onclick={loadData} title="Refresh">
      <RefreshCwIcon class="size-3.5" />
    </button>
  </div>

  <!-- ── AD Model Tab ── -->
  {#if activeSubTab === 'ad'}
    {#if loading}
      <div class="state-center"><div class="spinner"></div><span>Loading…</span></div>
    {:else if errorMsg}
      <div class="state-center error">
        <ShieldAlertIcon class="size-5" style="color:#e57373" />
        {errorMsg}
      </div>
    {:else}
      <div class="content">

        <!-- Rule banner -->
        <div class="rule-banner">
          <span class="rule-label">Classification rule</span>
          <span class="rule-text">Anomaly score &gt; {THRESHOLD} → <span style="color:#e57373">ANOMALY</span> &nbsp;·&nbsp; Otherwise → <span style="color:#70c1a3">GOOD</span> &nbsp;·&nbsp; Sample of 50 images from 2,849,150 total</span>
        </div>

        <!-- KPI -->
        <div class="kpi-row">
          <div class="kpi-card">
            <div class="kpi-label">Sample Size</div>
            <div class="kpi-value">{fmtNum(total)}</div>
            <div class="kpi-sub">Sep 30 – Nov 12, 2025</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Anomalies</div>
            <div class="kpi-value" style="color:#e57373">{fmtNum(anomCount)}</div>
            <div class="kpi-sub" style="color:#e57373">{anomPct}% of sample</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Anomaly Rate</div>
            <div class="kpi-value" style="color:#e57373">{anomPct}%</div>
            <div class="kpi-sub">{goodPct}% good</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Total in Bucket</div>
            <div class="kpi-value">2.85M</div>
            <div class="kpi-sub">~2% system anomaly rate</div>
          </div>
        </div>

        <!-- Charts row -->
        <div class="charts-2col">
          <!-- Score distribution histogram -->
          <div class="chart-card">
            <div class="chart-title">Anomaly Score Distribution <span class="chart-title-note">threshold {THRESHOLD}</span></div>
            <svg viewBox="0 0 {W} {H}" class="chart-svg">
              {#each [0, 0.5, 1] as t}
                <line x1={PAD.l} x2={W - PAD.r} y1={PAD.t + ch * (1 - t)} y2={PAD.t + ch * (1 - t)} stroke="rgba(145,145,145,0.08)" stroke-width="1"/>
                <text x={PAD.l - 4} y={PAD.t + ch * (1 - t) + 3} text-anchor="end" font-size="8" fill="#555">{Math.round(scoreMax * t)}</text>
              {/each}
              {#each scoreDist() as count, i}
                {@const x = PAD.l + (i / BUCKETS) * cw}
                {@const barW = cw / BUCKETS - 1}
                {@const barH = (count / scoreMax) * ch}
                {@const midScore = (i + 0.5) / BUCKETS}
                {@const color = midScore >= THRESHOLD ? '#e57373' : '#70c1a3'}
                <rect x={x} y={PAD.t + ch - barH} width={barW} height={barH} fill={color} opacity="0.7" rx="1"/>
              {/each}
              <line x1={threshX} x2={threshX} y1={PAD.t} y2={PAD.t + ch} stroke="#e57373" stroke-width="1.5" stroke-dasharray="4 2"/>
              <text x={threshX + 3} y={PAD.t + 9} font-size="7" fill="#e57373">{THRESHOLD}</text>
              {#each [0, 0.25, 0.5, 0.75, 1.0] as v}
                <text x={PAD.l + v * cw} y={H - 6} text-anchor="middle" font-size="7" fill="#555">{v.toFixed(2)}</text>
              {/each}
            </svg>
            <div class="legend">
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(112,193,163,0.7)"></span>Good</span>
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(229,115,115,0.7)"></span>Anomaly</span>
            </div>
          </div>

          <!-- Good / Anomaly bar -->
          <div class="chart-card">
            <div class="chart-title">Sample Summary</div>
            <div class="bar-chart" style="margin-top:16px">
              {#each [
                { label: 'Good',    val: goodCount, color: '#70c1a3' },
                { label: 'Anomaly', val: anomCount, color: '#e57373' },
              ] as row}
                {@const pct = (row.val / Math.max(total, 1) * 100).toFixed(1)}
                <div class="bar-row">
                  <div class="bar-label">{row.label}</div>
                  <div class="bar-track"><div class="bar-fill" style="width:{pct}%;background:{row.color}"></div></div>
                  <div class="bar-val" style="color:{row.color}">{fmtNum(row.val)}</div>
                </div>
              {/each}
            </div>

            <!-- Period context -->
            <div style="margin-top:20px">
              <div class="chart-title" style="margin-bottom:8px">Production Context</div>
              <table class="table">
                <thead><tr><th>Period</th><th>Status</th><th>Anomaly Rate</th></tr></thead>
                <tbody>
                  <tr><td>Sep 30 – Oct 6</td><td style="color:#fbbf24">Calibration</td><td class="mono" style="color:#fbbf24">~45%</td></tr>
                  <tr><td>Oct 24 – Nov 5</td><td style="color:#70c1a3">Stable</td><td class="mono" style="color:#70c1a3">~2%</td></tr>
                  <tr><td>Nov 7 – Nov 12</td><td style="color:#e57373">System Failure</td><td class="mono" style="color:#e57373">~92%</td></tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>

        <!-- Image Gallery -->
        {#if samples.length > 0}
          <div class="chart-card" style="margin-bottom:28px">
            <div class="chart-title-row">
              <div class="chart-title">
                Image Gallery — {filteredSamples.length} sample{filteredSamples.length !== 1 ? 's' : ''}
              </div>
            </div>

            <div class="gallery-filters">
              <span class="gallery-filter-meta">Robinson AD model sample · 50 images</span>
              {#each ([
                { key: 'all', label: 'All', color: '#888' },
                { key: 'anomaly', label: 'Anomaly', color: '#e57373' },
                { key: 'good', label: 'Good', color: '#70c1a3' },
              ] as { key: 'all'|'anomaly'|'good', label: string, color: string }[]) as f}
                <button
                  class="filter-pill {galleryFilter === f.key ? 'filter-pill-active' : ''}"
                  style="--pc:{f.color}"
                  onclick={() => galleryFilter = f.key}
                >{f.label}</button>
              {/each}
            </div>

            <div class="gallery-grid">
              {#each filteredSamples as sample}
                <button class="gallery-card" onclick={() => lightboxSample = sample}>
                  <div class="gallery-img-wrap">
                    <img src="{import.meta.env.BASE_URL}images/{sample.key}.jpg" alt={sample.key} loading="lazy"/>
                    <span class="gallery-badge {sample.anomalous ? 'badge-defect' : 'badge-pass'}">
                      {sample.anomalous ? 'ANOMALY' : 'GOOD'}
                    </span>
                  </div>
                  <div class="gallery-meta">
                    <span class="gallery-key">{sample.key.slice(0, 8)}</span>
                    <span style="color:{sample.score >= THRESHOLD ? '#e57373' : '#70c1a3'};font-size:9px;font-weight:600;font-family:monospace">{sample.score.toFixed(3)}</span>
                  </div>
                </button>
              {/each}
            </div>
          </div>
        {/if}

      </div>
    {/if}

  <!-- ── All Images Tab ── -->
  {:else}
    {#if loading}
      <div class="state-center"><div class="spinner"></div><span>Loading…</span></div>
    {:else if errorMsg}
      <div class="state-center error">{errorMsg}</div>
    {:else}
      <div class="content">
        <div class="rule-banner">
          <span class="rule-label">Raw images</span>
          <span class="rule-text">50 samples from S3 bucket · {anomCount} anomalous · {goodCount} good</span>
        </div>
        <div class="chart-card" style="margin-bottom:28px">
          <div class="chart-title">All Samples — {total} images</div>
          <div class="gallery-grid">
            {#each samples as sample}
              <button class="gallery-card" onclick={() => lightboxSample = sample}>
                <div class="gallery-img-wrap">
                  <img src="{import.meta.env.BASE_URL}images/{sample.key}.jpg" alt={sample.key} loading="lazy"/>
                  <span class="gallery-badge {sample.anomalous ? 'badge-defect' : 'badge-pass'}">
                    {sample.anomalous ? 'ANOMALY' : 'GOOD'}
                  </span>
                </div>
                <div class="gallery-meta">
                  <span class="gallery-key">{sample.key.slice(0, 8)}</span>
                  <span style="color:#555;font-size:9px;font-family:monospace">{sample.score.toFixed(3)}</span>
                </div>
              </button>
            {/each}
          </div>
        </div>
      </div>
    {/if}
  {/if}
</div>

<style>
  .wrap {
    height: 100%; overflow-y: auto; scrollbar-width: none;
    background: var(--bg-canvas);
    background-image: radial-gradient(circle, var(--dot-color) 0.5px, transparent 0.5px);
    background-size: 20px 20px;
    color: var(--foreground);
  }
  .wrap::-webkit-scrollbar { display: none; }

  .header {
    position: sticky; top: 0; z-index: 10;
    display: flex; align-items: center; gap: 12px; padding: 10px 24px;
    background: var(--topbar-bg); border-bottom: 1px solid var(--surface-border);
    backdrop-filter: blur(8px); flex-wrap: wrap;
  }
  .header-left { display: flex; align-items: center; gap: 10px; flex: 1; min-width: 0; }
  .title { font-size: 14px; font-weight: 700; color: var(--text-1); line-height: 1; }
  .subtitle { font-size: 11px; color: var(--text-3); margin-top: 2px; }

  .subtabs { display: flex; gap: 4px; background: var(--surface-2); border-radius: 8px; padding: 3px; }
  .subtab {
    display: flex; align-items: center; gap: 5px;
    padding: 5px 12px; border-radius: 6px; font-size: 12px; font-weight: 500;
    cursor: pointer; border: none; color: var(--text-3);
    background: transparent; transition: all .15s;
  }
  .subtab:hover { color: var(--text-1); }
  .subtab-active { background: var(--surface-1); color: var(--text-1); box-shadow: 0 1px 3px rgba(0,0,0,0.2); }

  .btn-icon {
    width: 30px; height: 30px; border-radius: 6px; display: flex; align-items: center; justify-content: center;
    background: var(--surface-2); border: 1px solid var(--surface-border); cursor: pointer;
    color: var(--text-3); transition: background .15s;
  }
  .btn-icon:hover { background: var(--surface-3); color: var(--text-1); }

  .content { padding: 16px 24px; display: flex; flex-direction: column; gap: 14px; }

  .state-center {
    flex: 1; display: flex; flex-direction: column; align-items: center;
    justify-content: center; gap: 12px; padding: 80px 40px;
    color: var(--text-3); font-size: 13px; text-align: center;
  }
  .state-center.error { color: #e57373; }
  .spinner {
    width: 26px; height: 26px; border-radius: 50%;
    border: 2px solid rgba(112,193,163,0.2); border-top-color: #70c1a3;
    animation: spin .8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  .rule-banner {
    display: flex; align-items: center; gap: 10px;
    background: var(--surface-1); border: 1px solid var(--surface-border);
    border-left: 3px solid #70c1a3;
    border-radius: 8px; padding: 10px 14px; font-size: 12px;
  }
  .rule-label { font-size: 10px; text-transform: uppercase; letter-spacing: .6px; color: var(--text-3); white-space: nowrap; }
  .rule-text  { color: var(--text-2); }

  .kpi-row { display: grid; grid-template-columns: repeat(4,1fr); gap: 12px; }
  .kpi-card { background: var(--surface-1); border: 1px solid var(--surface-border); border-radius: 10px; padding: 16px 18px; }
  .kpi-label { font-size: 10px; text-transform: uppercase; letter-spacing: .7px; color: var(--text-3); margin-bottom: 6px; }
  .kpi-value { font-size: 1.9rem; font-weight: 800; line-height: 1; color: var(--text-1); font-variant-numeric: tabular-nums; }
  .kpi-sub { font-size: 10px; color: var(--text-3); margin-top: 5px; }

  .charts-2col { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
  .chart-card { background: var(--surface-1); border: 1px solid var(--surface-border); border-radius: 10px; padding: 16px 18px; }
  .chart-title { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .5px; color: var(--text-3); margin-bottom: 10px; }
  .chart-title-note { font-size: 9px; font-weight: 400; letter-spacing: .3px; text-transform: none; color: var(--text-3); opacity: .7; margin-left: 6px; }
  .chart-svg { width: 100%; overflow: visible; }
  .legend { display: flex; gap: 14px; margin-top: 6px; }
  .leg-box-item { font-size: 10px; color: var(--text-3); display: flex; align-items: center; gap: 5px; }
  .leg-box { display: inline-block; width: 12px; height: 12px; border-radius: 2px; flex-shrink: 0; }

  .bar-chart { display: flex; flex-direction: column; gap: 10px; margin-top: 4px; }
  .bar-row { display: flex; align-items: center; gap: 8px; }
  .bar-label { font-size: 11px; color: var(--text-3); width: 60px; flex-shrink: 0; }
  .bar-track { flex: 1; height: 8px; background: var(--surface-3); border-radius: 99px; overflow: hidden; }
  .bar-fill { height: 100%; border-radius: 99px; transition: width .5s ease; }
  .bar-val { font-size: 11px; font-weight: 600; width: 50px; text-align: right; font-variant-numeric: tabular-nums; }

  .chart-title-row { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
  .chart-title-row .chart-title { margin-bottom: 0; }

  .table { width: 100%; border-collapse: collapse; font-size: 12px; }
  .table th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: .5px; color: var(--text-3); padding: 5px 10px; border-bottom: 1px solid var(--surface-border); }
  .table td { padding: 9px 10px; border-bottom: 1px solid var(--surface-border); color: var(--text-1); }
  .table tr:last-child td { border-bottom: none; }
  .mono { font-family: monospace; color: var(--text-2); }

  .gallery-filters { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; margin-bottom: 14px; }
  .gallery-filter-meta { font-size: 11px; color: var(--text-3); margin-right: 4px; }
  .filter-pill {
    display: inline-flex; align-items: center; gap: 5px;
    padding: 4px 12px; border-radius: 99px; font-size: 11px; font-weight: 500;
    border: 1px solid color-mix(in srgb, var(--pc) 40%, transparent);
    color: color-mix(in srgb, var(--pc) 60%, var(--text-3));
    background: transparent; cursor: pointer;
    transition: all .15s; opacity: 0.6;
  }
  .filter-pill::before { content: ''; width: 7px; height: 7px; border-radius: 50%; background: var(--pc); flex-shrink: 0; opacity: 0.5; transition: opacity .15s; }
  .filter-pill:hover { opacity: 0.85; }
  .filter-pill-active {
    background: color-mix(in srgb, var(--pc) 18%, transparent);
    border-color: var(--pc); color: var(--pc);
    font-weight: 700; opacity: 1;
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--pc) 30%, transparent);
  }
  .filter-pill-active::before { opacity: 1; }
  .filter-pill-active::after { content: '✓'; font-size: 10px; margin-left: 2px; }

  .gallery-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
    gap: 10px;
  }
  .gallery-card {
    background: none; border: 1px solid var(--surface-border);
    border-radius: 8px; overflow: hidden; cursor: zoom-in;
    transition: border-color .15s, transform .1s;
    text-align: left; padding: 0;
  }
  .gallery-card:hover { border-color: #70c1a3; transform: translateY(-1px); }
  .gallery-img-wrap { position: relative; aspect-ratio: 1; overflow: hidden; background: #111; }
  .gallery-img-wrap img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .gallery-badge {
    position: absolute; top: 5px; right: 5px;
    font-size: 9px; font-weight: 700; letter-spacing: .5px;
    padding: 2px 6px; border-radius: 3px;
  }
  .badge-defect { background: rgba(229,115,115,0.9); color: #fff; }
  .badge-pass   { background: rgba(112,193,163,0.9); color: #0a1a14; }
  .gallery-meta {
    padding: 6px 8px; display: flex; justify-content: space-between;
    align-items: center; background: var(--surface-2);
  }
  .gallery-key { font-size: 9px; font-family: monospace; color: var(--text-3); }

  /* ── Lightbox ── */
  .lightbox {
    position: fixed; inset: 0; z-index: 9999;
    background: rgba(0,0,0,0.92); backdrop-filter: blur(8px);
    display: flex; align-items: center; justify-content: center;
    cursor: zoom-out; padding: 20px;
  }
  .lb-inner {
    display: flex; flex-direction: column; align-items: center; gap: 14px;
    cursor: default; max-width: min(92vw, 560px); width: 100%;
  }
  .lb-img { width: 100%; aspect-ratio: 1; object-fit: contain; border-radius: 10px; box-shadow: 0 8px 48px rgba(0,0,0,0.7); }
  .lb-info { width: 100%; display: flex; flex-direction: column; gap: 8px; }
  .lb-key { font-family: monospace; font-size: 11px; color: #888; }
  .lb-tags { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .lb-status { font-size: 11px; font-weight: 700; letter-spacing: .5px; padding: 3px 8px; border-radius: 4px; }
  .lb-defect { background: rgba(229,115,115,0.2); color: #e57373; }
  .lb-pass   { background: rgba(112,193,163,0.2); color: #70c1a3; }
  .lb-tag { font-size: 12px; font-weight: 500; }
  .lb-hint { font-size: 10px; color: #555; }
  .lb-counter { font-size: 11px; color: #555; margin-left: 8px; }
  .lb-nav {
    position: fixed; top: 50%; transform: translateY(-50%);
    background: rgba(30,30,30,0.7); border: 1px solid rgba(255,255,255,0.1);
    color: #ccc; font-size: 22px; width: 44px; height: 44px; border-radius: 50%;
    cursor: pointer; display: flex; align-items: center; justify-content: center;
    z-index: 10001; transition: background 0.15s, color 0.15s;
  }
  .lb-nav:hover { background: rgba(60,60,60,0.9); color: #fff; }
  .lb-nav-prev { left: 16px; }
  .lb-nav-next { right: 16px; }
</style>
