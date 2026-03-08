<script lang="ts">
  import { onMount } from 'svelte';
  import DatabaseIcon from '@lucide/svelte/icons/database';
  import ActivityIcon from '@lucide/svelte/icons/activity';
  import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
  import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
  import ShieldAlertIcon from '@lucide/svelte/icons/shield-alert';

  // ── Sub-tab ────────────────────────────────────────────────────────────────
  let activeSubTab = $state<'sam3' | 'ad'>('sam3');

  // ── SAM3 data ──────────────────────────────────────────────────────────────
  type Sample = {
    path: string; key: string;
    crown: number;
    thread: number; cavity_markers: number; underfilling: number;
    thread_conf: number; cavity_conf: number; underfill_conf: number;
    defect_detected: boolean;
  };

  type Sam3Stats = {
    total: number; processed: number;
    defects: number; pass: number;
    defectPct: string; passPct: string;
    classes: { crown: number; crown_under: number; crown_over: number; thread: number; cavity_markers: number; underfilling: number };
    hourly: { hour: number; total: number; defects: number }[];
    date: string;
    samples?: Sample[];
  };

  // ── AD data ────────────────────────────────────────────────────────────────
  type AdSample = { key: string; path: string; brightness: number; anomaly: boolean; datetime: string; hour: number };
  type AdStats = {
    total: number; anomaly: number; pass: number;
    anomalyPct: string; passPct: string;
    threshold: number;
    hourly: { hour: number; total: number; anomaly: number; good: number }[];
    scoreDist: number[];
    samples: AdSample[];
  };

  let sam3 = $state<Sam3Stats | null>(null);
  let ad   = $state<AdStats | null>(null);
  let lightboxSample    = $state<Sample | null>(null);
  let lightboxAdSample  = $state<AdSample | null>(null);
  let annotatedSamples = $state<Sample[]>([]);
  let loadingSam3 = $state(true);
  let loadingAd   = $state(true);
  let errorSam3   = $state('');
  let errorAd     = $state('');

  function navigateSam3(dir: 1 | -1) {
    if (!lightboxSample) return;
    const list = filteredSamples;
    const idx = list.indexOf(lightboxSample);
    if (idx === -1) return;
    const next = list[(idx + dir + list.length) % list.length];
    lightboxSample = next;
  }

  function navigateAd(dir: 1 | -1) {
    if (!lightboxAdSample || !ad) return;
    const list = ad.samples;
    const idx = list.indexOf(lightboxAdSample);
    if (idx === -1) return;
    const next = list[(idx + dir + list.length) % list.length];
    lightboxAdSample = next;
  }

  function onKeydown(e: KeyboardEvent) {
    if (lightboxSample) {
      if (e.key === 'ArrowRight') { e.preventDefault(); navigateSam3(1); }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); navigateSam3(-1); }
      else if (e.key === 'Escape') lightboxSample = null;
    } else if (lightboxAdSample) {
      if (e.key === 'ArrowRight') { e.preventDefault(); navigateAd(1); }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); navigateAd(-1); }
      else if (e.key === 'Escape') lightboxAdSample = null;
    }
  }

  async function loadSam3() {
    loadingSam3 = true; errorSam3 = '';
    try {
      const r = await fetch(import.meta.env.BASE_URL + 'sam3_results.json');
      if (!r.ok) throw new Error('Not found');
      sam3 = await r.json();
    } catch (e) {
      errorSam3 = e instanceof Error ? e.message : 'Failed';
    } finally { loadingSam3 = false; }
    try {
      const r2 = await fetch(import.meta.env.BASE_URL + 'sam3_samples.json');
      if (r2.ok) annotatedSamples = await r2.json();
    } catch { /* optional */ }
  }

  async function loadAd() {
    loadingAd = true; errorAd = '';
    try {
      const r = await fetch(import.meta.env.BASE_URL + 'ad_sam3_results.json');
      if (!r.ok) throw new Error('AD stats not computed yet — run compute_ad_sam3.py');
      ad = await r.json();
    } catch (e) {
      errorAd = e instanceof Error ? e.message : 'Failed';
    } finally { loadingAd = false; }
  }

  onMount(() => {
    loadSam3(); loadAd();
    window.addEventListener('keydown', onKeydown);
    return () => window.removeEventListener('keydown', onKeydown);
  });

  // ── Chart helpers ──────────────────────────────────────────────────────────
  const W = 560; const H = 120;
  const PAD = { t: 10, r: 8, b: 28, l: 44 };
  const cw = W - PAD.l - PAD.r;
  const ch = H - PAD.t - PAD.b;

  // Wide chart (full-width cards) — larger viewBox keeps font sizes proportional
  const RW = 1100; const RH = 130;
  const RPAD = { t: 10, r: 12, b: 28, l: 52 };
  const rcw = RW - RPAD.l - RPAD.r;
  const rch = RH - RPAD.t - RPAD.b;

  function cdx(i: number, n: number) { return PAD.l + (i / Math.max(n - 1, 1)) * cw; }
  function cdy(v: number, max: number) { return PAD.t + ch - (v / Math.max(max, 1)) * ch; }
  function rcdx(i: number, n: number) { return RPAD.l + (i / Math.max(n - 1, 1)) * rcw; }
  function rcdy(v: number, max: number) { return RPAD.t + rch - (v / Math.max(max, 1)) * rch; }
  function polyline(pts: number[][]): string {
    return pts.map(([x,y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
  }
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

  // ── SAM3 derived ───────────────────────────────────────────────────────────
  const s3HourMax  = $derived(sam3 ? Math.max(...sam3.hourly.map(h => h.total), 1) : 1);
  const s3HourPts  = $derived(sam3 ? sam3.hourly.map((h,i) => [cdx(i,24), cdy(h.total, s3HourMax)]) : []);
  const s3DefPts   = $derived(sam3 ? sam3.hourly.map((h,i) => [cdx(i,24), cdy(h.defects, s3HourMax)]) : []);
  const s3ClassMax = $derived(sam3 ? Math.max(...Object.values(sam3.classes), 1) : 1);
  const RATE_START = 7;  // clock hour shown at left edge
  function rateX(pos: number): number { return RPAD.l + (pos / 23) * rcw; }

  const s3RateDisplayMax = $derived(
    sam3 ? Math.ceil(Math.max(...sam3.hourly.filter(h => h.total > 0).map(h => h.defects / h.total * 100), 0.1) * 1.4) : 5
  );
  const s3RatePts = $derived(
    sam3 ? Array.from({length: 24}, (_, i) => {
      const hour = (i + RATE_START) % 24;
      const h = sam3.hourly.find(hh => hh.hour === hour);
      const rate = h && h.total > 0 ? h.defects / h.total * 100 : 0;
      return [rateX(i), rcdy(rate, s3RateDisplayMax)];
    }) : []
  );

  // ── AD derived ─────────────────────────────────────────────────────────────
  const adHourMax   = $derived(ad ? Math.max(...ad.hourly.map(h => h.total), 1) : 1);
  const adScoreMax  = $derived(ad ? Math.max(...ad.scoreDist.filter((_,i) => i >= 80), 1) : 1);
  const adThreshX   = $derived(ad ? PAD.l + ((ad.threshold - 80) / 175) * cw : 0);

  // Hourly bar chart constants
  const HW = 520, HH = 140, HPL = 36, HPB = 22;
  const hbw = (HW - HPL - 4) / 24 - 2;

  const SAM3_CLASSES = [
    { key: 'crown_under'  as const, label: 'Crown < 4',      color: '#e57373' },
    { key: 'crown_over'   as const, label: 'Crown > 4',      color: '#fb923c' },
    { key: 'thread'       as const, label: 'Thread',         color: '#fbbf24' },
    { key: 'cavity_markers' as const, label: 'Cavity Markers', color: '#e57373' },
    { key: 'underfilling' as const, label: 'Underfilling',   color: '#a78bfa' },
  ];

  type ClassKey = 'crown_under' | 'crown_over' | 'thread' | 'cavity_markers' | 'underfilling'
               | 'ok' | 'defect'
               | 'cavity_1' | 'cavity_2' | 'cavity_3' | 'cavity_4';
  let galleryFilters = $state<Set<ClassKey>>(new Set());
  let sidebarOpen = $state(false);

  function toggleFilter(key: ClassKey) {
    const next = new Set(galleryFilters);
    next.has(key) ? next.delete(key) : next.add(key);
    galleryFilters = next;
  }

  // Thresholds matching recompute_sam3_stats.py
  const THREAD_THRESH    = 0.82;
  const CAVITY_THRESH    = 0.70;
  const UNDERFILL_THRESH = 0.55;

  function matchesAny(sample: Sample): boolean {
    if (galleryFilters.has('ok')             && !sample.defect_detected) return true;
    if (galleryFilters.has('defect')         && sample.defect_detected) return true;
    if (galleryFilters.has('crown_under')    && sample.crown < 4) return true;
    if (galleryFilters.has('crown_over')     && sample.crown > 4) return true;
    if (galleryFilters.has('thread')         && (sample.thread_conf ?? 0) >= THREAD_THRESH) return true;
    if (galleryFilters.has('cavity_markers') && (sample.cavity_conf    ?? 0) >= CAVITY_THRESH) return true;
    if (galleryFilters.has('underfilling')   && (sample.underfill_conf ?? 0) >= UNDERFILL_THRESH) return true;
    if (galleryFilters.has('cavity_1')       && sample.cavity_markers === 1) return true;
    if (galleryFilters.has('cavity_2')       && sample.cavity_markers === 2) return true;
    if (galleryFilters.has('cavity_3')       && sample.cavity_markers === 3) return true;
    if (galleryFilters.has('cavity_4')       && sample.cavity_markers === 4) return true;
    return false;
  }

  const filteredSamples = $derived(
    galleryFilters.size > 0
      ? annotatedSamples.filter(matchesAny)
      : annotatedSamples
  );
</script>

<!-- Lightbox -->
{#if lightboxSample}
  {@const lbIdx = filteredSamples.indexOf(lightboxSample)}
  <div class="lightbox" onclick={() => (lightboxSample = null)} role="dialog" aria-modal="true">
    <button class="lb-nav lb-nav-prev" onclick={(e) => { e.stopPropagation(); navigateSam3(-1); }} aria-label="Previous">&#8592;</button>
    <div class="lb-inner lb-wide" onclick={(e) => e.stopPropagation()}>
      <div class="lb-pair">
        <div class="lb-pair-col">
          <div class="lb-pair-label">Original</div>
          <img src="{import.meta.env.BASE_URL}parts/{lightboxSample.key}.jpg" alt="original" class="lb-img"/>
        </div>
        <div class="lb-pair-col">
          <div class="lb-pair-label">SAM3 Segmentation</div>
          <img src="{import.meta.env.BASE_URL}annotated/{lightboxSample.key}.jpg" alt="annotated" class="lb-img"/>
        </div>
      </div>
      <div class="lb-info">
        <div class="lb-key">{lightboxSample.key} <span class="lb-counter">{lbIdx + 1} / {filteredSamples.length}</span></div>
        <div class="lb-tags">
          <span class="lb-status {lightboxSample.defect_detected ? 'lb-defect' : 'lb-pass'}">
            {lightboxSample.defect_detected ? 'DEFECT' : 'PASS'}
          </span>
          {#if lightboxSample.crown > 0}<span class="lb-tag" style="color:#70c1a3">Crown ×{lightboxSample.crown}</span>{/if}
          {#if (lightboxSample.thread_conf ?? 0) >= THREAD_THRESH}<span class="lb-tag" style="color:#fbbf24">Thread {(lightboxSample.thread_conf ?? 0).toFixed(2)}</span>{/if}
          {#if (lightboxSample.cavity_conf ?? 0) >= CAVITY_THRESH}<span class="lb-tag" style="color:#e57373">Cavity {(lightboxSample.cavity_conf ?? 0).toFixed(2)}</span>{/if}
          {#if (lightboxSample.underfill_conf ?? 0) >= UNDERFILL_THRESH}<span class="lb-tag" style="color:#a78bfa">Underfill {(lightboxSample.underfill_conf ?? 0).toFixed(2)}</span>{/if}
        </div>
        <div class="lb-hint">← → to navigate · Esc to close</div>
      </div>
    </div>
    <button class="lb-nav lb-nav-next" onclick={(e) => { e.stopPropagation(); navigateSam3(1); }} aria-label="Next">&#8594;</button>
  </div>
{/if}

<!-- AD Lightbox -->
{#if lightboxAdSample && ad}
  {@const adIdx = ad.samples.indexOf(lightboxAdSample)}
  <div class="lightbox" onclick={() => (lightboxAdSample = null)} role="dialog" aria-modal="true">
    <button class="lb-nav lb-nav-prev" onclick={(e) => { e.stopPropagation(); navigateAd(-1); }} aria-label="Previous">&#8592;</button>
    <div class="lb-inner lb-wide" onclick={(e) => e.stopPropagation()}>
      <img
        src="{import.meta.env.BASE_URL}ad-annotated/{lightboxAdSample.key}.jpg"
        alt={lightboxAdSample.key}
        class="lb-img"
      />
      <div class="lb-info">
        <div class="lb-key">{lightboxAdSample.datetime} <span class="lb-counter">{adIdx + 1} / {ad.samples.length}</span></div>
        <div class="lb-tags">
          <span class="lb-status lb-defect">ANOMALY</span>
          <span class="lb-tag" style="color:#e57373">Score: {lightboxAdSample.brightness}</span>
          <span class="lb-tag" style="color:#555">threshold {lightboxAdSample.brightness > 178.5 ? '↑' : '↓'} 178.5</span>
        </div>
        <div class="lb-hint">← → to navigate · Esc to close</div>
      </div>
    </div>
    <button class="lb-nav lb-nav-next" onclick={(e) => { e.stopPropagation(); navigateAd(1); }} aria-label="Next">&#8594;</button>
  </div>
{/if}

<div class="wrap">
  <!-- Header -->
  <div class="header">
    <div class="header-left">
      <DatabaseIcon class="size-4" style="color:#70c1a3" />
      <div>
        <h1 class="title">Real Dataset — AVK-Plast Jan 14, 2026</h1>
        <p class="subtitle">5,036 real part images from S3</p>
      </div>
    </div>

    <!-- Sub-tabs -->
    <div class="subtabs">
      <button class="subtab {activeSubTab === 'sam3' ? 'subtab-active' : ''}" onclick={() => activeSubTab = 'sam3'}>
        <DatabaseIcon class="size-3.5" />
        SAM3 · avk-ring/15
      </button>
      <button class="subtab {activeSubTab === 'ad' ? 'subtab-active' : ''}" onclick={() => activeSubTab = 'ad'}>
        <ActivityIcon class="size-3.5" />
        Original AD Model
      </button>
    </div>

    <button class="btn-icon" onclick={() => activeSubTab === 'sam3' ? loadSam3() : loadAd()} title="Refresh">
      <RefreshCwIcon class="size-3.5" />
    </button>
  </div>

  <!-- ── SAM3 Tab ── -->
  {#if activeSubTab === 'sam3'}
    {#if loadingSam3}
      <div class="state-center"><div class="spinner"></div><span>Loading…</span></div>
    {:else if errorSam3}
      <div class="state-center error">{errorSam3}</div>
    {:else if sam3}
      <div class="content">

        <!-- Rule banner -->
        <div class="rule-banner">
          <span class="rule-label">Classification rule</span>
          <span class="rule-text">Crown ≠ 4 → <span style="color:#e57373">DEFECT</span> &nbsp;·&nbsp; Thread ≥ 1 → <span style="color:#e57373">DEFECT</span> &nbsp;·&nbsp; Underfilling ≥ 1 → <span style="color:#e57373">DEFECT</span> &nbsp;·&nbsp; Otherwise → <span style="color:#70c1a3">PASS</span></span>
        </div>

        <!-- KPI -->
        <div class="kpi-row">
          <div class="kpi-card">
            <div class="kpi-label">Total Units Inspected</div>
            <div class="kpi-value">{fmtNum(sam3.total)}</div>
            <div class="kpi-sub">Jan 14, 2026</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Defects</div>
            <div class="kpi-value" style="color:#e57373">{fmtNum(sam3.defects)}</div>
            <div class="kpi-sub" style="color:#e57373">{sam3.defectPct}%</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Defect Rate</div>
            <div class="kpi-value" style="color:#e57373">{sam3.defectPct}%</div>
            <div class="kpi-sub">{sam3.passPct}% pass</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Parts per Hour</div>
            <div class="kpi-value">{fmtNum(Math.round(sam3.total / Math.max(sam3.hourly.filter(h => h.total > 0).length, 1)))}</div>
            <div class="kpi-sub">avg · active hours</div>
          </div>
        </div>

        <!-- Charts row 1 -->
        <div class="charts-2col">
          <div class="chart-card">
            <div class="chart-title">Hourly Distribution</div>
            <svg viewBox="0 0 {HW} {HH}" class="chart-svg">
              {#each [0, 0.25, 0.5, 0.75, 1] as t}
                <line x1={HPL} x2={HW - 2} y1={HH - HPB - t * (HH - HPB - 8)} y2={HH - HPB - t * (HH - HPB - 8)} stroke="rgba(145,145,145,0.08)" stroke-width="1"/>
                <text x={HPL - 4} y={HH - HPB - t * (HH - HPB - 8) + 3} text-anchor="end" font-size="8" fill="#555">{(v => v >= 1000 ? (v/1000).toFixed(1)+'k' : v)(Math.round(s3HourMax * t))}</text>
              {/each}
              {#each sam3.hourly as h}
                <rect x={HPL + h.hour * ((HW - HPL - 4) / 24)} y={HH - HPB - (s3HourMax > 0 ? ((h.total - h.defects) / s3HourMax) * (HH - HPB - 8) : 0) - (s3HourMax > 0 ? (h.defects / s3HourMax) * (HH - HPB - 8) : 0)} width={hbw} height={s3HourMax > 0 ? ((h.total - h.defects) / s3HourMax) * (HH - HPB - 8) : 0} fill="rgba(112,193,163,0.55)" rx="1"/>
                <rect x={HPL + h.hour * ((HW - HPL - 4) / 24)} y={HH - HPB - (s3HourMax > 0 ? (h.defects / s3HourMax) * (HH - HPB - 8) : 0)} width={hbw} height={s3HourMax > 0 ? (h.defects / s3HourMax) * (HH - HPB - 8) : 0} fill="rgba(229,115,115,0.85)" rx="1"/>
                {#if h.hour % 3 === 0}
                  <text x={HPL + h.hour * ((HW - HPL - 4) / 24) + hbw/2} y={HH - 6} text-anchor="middle" font-size="8" fill="#555">{String(h.hour).padStart(2,'0')}h</text>
                {/if}
              {/each}
            </svg>
            <div class="legend">
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(112,193,163,0.55)"></span>Good</span>
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(229,115,115,0.85)"></span>Defect</span>
            </div>
          </div>

          <div class="chart-card">
            <div class="chart-title">Class Summary <span class="chart-title-note">units affected</span></div>
            <div class="bar-chart">
              {#each SAM3_CLASSES as cls}
                {@const val = sam3.classes[cls.key]}
                {@const pct = (val / s3ClassMax * 100).toFixed(1)}
                {@const active = galleryFilters.has(cls.key)}
                <button
                  class="bar-row bar-row-btn {active ? 'bar-row-active' : ''}"
                  onclick={() => toggleFilter(cls.key)}
                  title="{active ? 'Remove filter' : `Filter gallery by ${cls.label}`}"
                >
                  <div class="bar-label">{cls.label}</div>
                  <div class="bar-track"><div class="bar-fill" style="width:{pct}%;background:{cls.color};opacity:{active ? 1 : 0.7}"></div></div>
                  <div class="bar-val" style="color:{cls.color}">{fmtNum(val)}</div>
                  {#if active}<span class="bar-active-dot" style="background:{cls.color}"></span>{/if}
                </button>
              {/each}
            </div>
          </div>
        </div>

        <!-- Defect rate chart -->
        <div class="chart-card chart-wide">
          <div class="chart-title">Hourly Defect Rate <span class="chart-title-note">% of inspections</span></div>
          <svg viewBox="0 0 {RW} {RH}" class="chart-svg" style="width:100%">
            <defs>
              <linearGradient id="rateGrad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stop-color="#e57373" stop-opacity="0.18"/>
                <stop offset="100%" stop-color="#e57373" stop-opacity="0"/>
              </linearGradient>
            </defs>
            {#each [0, 0.5, 1] as t}
              {@const y = RPAD.t + rch * (1 - t)}
              {@const label = (s3RateDisplayMax * t).toFixed(1)}
              <line x1={RPAD.l} x2={RW-RPAD.r} y1={y} y2={y} stroke="rgba(145,145,145,0.07)" stroke-width="1"/>
              <text x={RPAD.l-4} y={y+3} text-anchor="end" font-size="8" fill="#555">{label}%</text>
            {/each}
            {#each Array.from({length: 24}, (_, i) => i) as i}
              {#if i % 3 === 0}
                <text x={rateX(i)} y={RH-6} text-anchor="middle" font-size="8" fill="#555">{String((i + RATE_START) % 24).padStart(2,'0')}</text>
              {/if}
            {/each}
            <path d={smoothFillPath(s3RatePts, RPAD.t + rch)} fill="url(#rateGrad)"/>
            <path d={smoothPath(s3RatePts)} fill="none" stroke="#e57373" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
          </svg>
        </div>

        <!-- Summary table -->
        <div class="chart-card chart-wide">
          <div class="chart-title">Class Summary</div>
          <table class="table">
            <thead><tr>
              <th>Class</th><th>Units affected</th><th>% of total</th><th>Note</th>
            </tr></thead>
            <tbody>
              {#each SAM3_CLASSES as cls}
                {@const val = sam3.classes[cls.key]}
                <tr>
                  <td><span class="dot" style="background:{cls.color}"></span>{cls.label}</td>
                  <td class="mono">{fmtNum(val)}</td>
                  <td class="mono">{(val/Math.max(sam3.total,1)*100).toFixed(1)}%</td>
                  <td class="mono" style="color:var(--text-3);font-size:10px">{cls.key === 'crown_under' ? 'fewer than 4' : cls.key === 'crown_over' ? 'more than 4' : '≥ 1 detection'}</td>

                </tr>
              {/each}
            </tbody>
          </table>
        </div>

        <!-- Image Gallery -->
        {#if annotatedSamples.length > 0}
          <div class="chart-card chart-wide" style="margin-bottom:28px">
            <div class="chart-title-row">
              <div class="chart-title">
                Instance Segmentation Gallery — {filteredSamples.length} sample{filteredSamples.length !== 1 ? 's' : ''}
              </div>
            </div>
            <div class="gallery-layout">
              <div class="gallery-main">
                <div class="gallery-filters">
                  <span class="gallery-filter-meta">Annotated with SAM3 · avk-ring/15</span>
                  {#each SAM3_CLASSES as cls}
                    {@const active = galleryFilters.has(cls.key)}
                    <button
                      class="filter-pill {active ? 'filter-pill-active' : ''}"
                      style="--pc:{cls.color}"
                      onclick={() => toggleFilter(cls.key)}
                    >{cls.label}</button>
                  {/each}
                  {#if galleryFilters.size > 0}
                    <button class="filter-pill-reset" onclick={() => galleryFilters = new Set()}>Clear</button>
                  {/if}
                </div>
                <div class="gallery-grid">
                  {#each filteredSamples as sample}
                    <button class="gallery-card sam3-gallery-card" onclick={() => (lightboxSample = sample)}>
                      <div class="gallery-img-wrap gallery-img-pair">
                        <img src="{import.meta.env.BASE_URL}parts/{sample.key}.jpg" alt="original" loading="lazy" class="gallery-half"/>
                        <img src="{import.meta.env.BASE_URL}annotated/{sample.key}.jpg" alt="annotated" loading="lazy" class="gallery-half"/>
                      </div>
                      <div class="gallery-meta">
                        <span class="gallery-key">{sample.key.slice(-8)}</span>
                        <span class="gallery-counts">
                          {#if sample.crown > 0}<span style="color:#70c1a3">C:{sample.crown}</span>{/if}
                          {#if (sample.thread_conf ?? 0) >= THREAD_THRESH}<span style="color:#fbbf24">T:{(sample.thread_conf ?? 0).toFixed(2)}</span>{/if}
                          {#if (sample.cavity_conf ?? 0) >= CAVITY_THRESH}<span style="color:#e57373">M:{(sample.cavity_conf ?? 0).toFixed(2)}</span>{/if}
                          {#if (sample.underfill_conf ?? 0) >= UNDERFILL_THRESH}<span style="color:#a78bfa">U:{(sample.underfill_conf ?? 0).toFixed(2)}</span>{/if}
                        </span>
                      </div>
                    </button>
                  {/each}
                </div>
              </div><!-- gallery-main -->

              <!-- Filter sidebar -->
              <div class="gallery-sidebar">
                <button class="sidebar-handle" onclick={() => sidebarOpen = !sidebarOpen} title={sidebarOpen ? 'Collapse filters' : 'Expand filters'}>
                  {#if galleryFilters.size > 0 && !sidebarOpen}<span class="sidebar-badge">{galleryFilters.size}</span>{/if}
                  <span class="sidebar-chevron" class:rotated={sidebarOpen}>›</span>
                </button>
                <div class="sidebar-body" class:sidebar-body-open={sidebarOpen}>
                  <div class="sidebar-body-inner">
                    <div class="sidebar-section">
                      <div class="sidebar-label">Status</div>
                      {#each [{key:'ok' as ClassKey, label:'OK', color:'#70c1a3'}, {key:'defect' as ClassKey, label:'NOK', color:'#e57373'}] as f}
                        <button
                          class="sidebar-pill {galleryFilters.has(f.key) ? 'sidebar-pill-active' : ''}"
                          style="--sc:{f.color}"
                          onclick={() => toggleFilter(f.key)}
                        >{f.label}</button>
                      {/each}
                    </div>
                    <div class="sidebar-section">
                      <div class="sidebar-label">Cavity markers</div>
                      {#each [1, 2, 3, 4] as n}
                        {@const key = `cavity_${n}` as ClassKey}
                        <button
                          class="sidebar-pill {galleryFilters.has(key) ? 'sidebar-pill-active' : ''}"
                          style="--sc:#e57373"
                          onclick={() => toggleFilter(key)}
                        >{n}×</button>
                      {/each}
                    </div>
                    {#if galleryFilters.size > 0}
                      <button class="sidebar-clear" onclick={() => galleryFilters = new Set()}>Clear all</button>
                    {/if}
                  </div>
                </div>
              </div>
            </div><!-- gallery-layout -->
          </div>
        {/if}

      </div>
    {/if}

  <!-- ── Original AD Tab ── -->
  {:else}
    {#if loadingAd}
      <div class="state-center"><div class="spinner"></div><span>Loading…</span></div>
    {:else if errorAd}
      <div class="state-center error">
        <ShieldAlertIcon class="size-5" style="color:#e57373" />
        {errorAd}
        <p class="error-hint">Run: <code>python3 compute_ad_sam3.py</code> in the illuin folder</p>
      </div>
    {:else if ad}
      <div class="content">

        <!-- Rule banner -->
        <div class="rule-banner">
          <span class="rule-label">Classification rule</span>
          <span class="rule-text">Brightness score &gt; {ad.threshold} → <span style="color:#e57373">ANOMALY</span> &nbsp;·&nbsp; Same 5,036 images as SAM3 dataset</span>
        </div>

        <!-- KPI -->
        <div class="kpi-row">
          <div class="kpi-card">
            <div class="kpi-label">Total Units Inspected</div>
            <div class="kpi-value">{fmtNum(ad.total)}</div>
            <div class="kpi-sub">Jan 14, 2026</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Anomalies</div>
            <div class="kpi-value" style="color:#e57373">{fmtNum(ad.anomaly)}</div>
            <div class="kpi-sub" style="color:#e57373">{ad.anomalyPct}%</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Anomaly Rate</div>
            <div class="kpi-value" style="color:#e57373">{ad.anomalyPct}%</div>
            <div class="kpi-sub">{ad.passPct}% pass rate</div>
          </div>
          <div class="kpi-card">
            <div class="kpi-label">Parts per Hour</div>
            <div class="kpi-value">{fmtNum(Math.round(ad.total / Math.max(ad.hourly.filter(h => h.total > 0).length, 1)))}</div>
            <div class="kpi-sub">avg · active hours</div>
          </div>
        </div>

        <!-- Charts row -->
        <div class="charts-2col">
          <!-- Hourly stacked bar -->
          <div class="chart-card">
            <div class="chart-title">Hourly Distribution</div>
            <svg viewBox="0 0 {HW} {HH}" class="chart-svg">
              {#each [0, 0.25, 0.5, 0.75, 1] as t}
                <line x1={HPL} x2={HW - 2} y1={HH - HPB - t * (HH - HPB - 8)} y2={HH - HPB - t * (HH - HPB - 8)} stroke="rgba(145,145,145,0.08)" stroke-width="1"/>
                <text x={HPL - 4} y={HH - HPB - t * (HH - HPB - 8) + 3} text-anchor="end" font-size="8" fill="#555">{(v => v >= 1000 ? (v/1000).toFixed(1)+'k' : v)(Math.round(adHourMax * t))}</text>
              {/each}
              {#each ad.hourly as h}
                <rect x={HPL + h.hour * ((HW - HPL - 4) / 24)} y={HH - HPB - (adHourMax > 0 ? ((h.total - h.anomaly) / adHourMax) * (HH - HPB - 8) : 0) - (adHourMax > 0 ? (h.anomaly / adHourMax) * (HH - HPB - 8) : 0)} width={hbw} height={adHourMax > 0 ? ((h.total - h.anomaly) / adHourMax) * (HH - HPB - 8) : 0} fill="rgba(112,193,163,0.55)" rx="1"/>
                <rect x={HPL + h.hour * ((HW - HPL - 4) / 24)} y={HH - HPB - (adHourMax > 0 ? (h.anomaly / adHourMax) * (HH - HPB - 8) : 0)} width={hbw} height={adHourMax > 0 ? (h.anomaly / adHourMax) * (HH - HPB - 8) : 0} fill="rgba(229,115,115,0.85)" rx="1"/>
                {#if h.hour % 3 === 0}
                  <text x={HPL + h.hour * ((HW - HPL - 4) / 24) + hbw/2} y={HH - 6} text-anchor="middle" font-size="8" fill="#555">{String(h.hour).padStart(2,'0')}h</text>
                {/if}
              {/each}
            </svg>
            <div class="legend">
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(112,193,163,0.55)"></span>Good</span>
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(229,115,115,0.85)"></span>Anomaly</span>
            </div>
          </div>

          <!-- Brightness score distribution -->
          <div class="chart-card">
            <div class="chart-title">Brightness Score Distribution <span class="chart-title-note">threshold {ad.threshold}</span></div>
            <svg viewBox="0 0 {W} {H}" class="chart-svg">
              {#each ad.scoreDist.slice(80) as count, i}
                {@const x = PAD.l + (i / 175) * cw}
                {@const barH = (count / adScoreMax) * ch}
                {@const brightness = i + 80}
                {@const color = brightness > ad.threshold ? '#e57373' : '#70c1a3'}
                <rect x={x} y={PAD.t + ch - barH} width={Math.max(cw/176, 1)} height={barH} fill={color} opacity="0.7"/>
              {/each}
              <line x1={adThreshX} x2={adThreshX} y1={PAD.t} y2={PAD.t+ch} stroke="#e57373" stroke-width="1.5" stroke-dasharray="4 2"/>
              <text x={adThreshX+3} y={PAD.t+9} font-size="7" fill="#e57373">{ad.threshold}</text>
              {#each [80,120,160,180,220,255] as v}
                <text x={PAD.l + ((v-80)/175)*cw} y={H-6} text-anchor="middle" font-size="7" fill="#555">{v}</text>
              {/each}
            </svg>
            <div class="legend">
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(112,193,163,0.7)"></span>Good</span>
              <span class="leg-box-item"><span class="leg-box" style="background:rgba(229,115,115,0.7)"></span>Anomaly</span>
            </div>
          </div>
        </div>

        <!-- Anomaly Image Gallery -->
        {#if ad.samples && ad.samples.length > 0}
          <div class="chart-card chart-wide" style="margin-bottom:28px">
            <div class="chart-title">
              Anomaly Gallery — {ad.samples.length} examples
              <span class="chart-title-note">original · heatmap overlay · score &gt; {ad.threshold}</span>
            </div>
            <div class="gallery-grid">
              {#each ad.samples as sample}
                <button class="gallery-card ad-gallery-card" onclick={() => (lightboxAdSample = sample)}>
                  <div class="gallery-img-wrap">
                    <img
                      src="{import.meta.env.BASE_URL}ad-annotated/{sample.key}.jpg"
                      alt={sample.key}
                      loading="lazy"
                    />
                  </div>
                  <div class="gallery-meta">
                    <span class="gallery-key">{sample.datetime}</span>
                    <span style="color:#e57373;font-size:10px;font-weight:600">{sample.brightness}</span>
                  </div>
                </button>
              {/each}
            </div>
          </div>
        {/if}

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
  .error-hint { font-size: 11px; color: var(--text-3); margin-top: 8px; }
  .error-hint code { font-family: monospace; background: var(--surface-2); padding: 2px 6px; border-radius: 4px; }
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
  .chart-wide { /* full width - already in flex column */ }
  .chart-title { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .5px; color: var(--text-3); margin-bottom: 10px; }
  .chart-title-note { font-size: 9px; font-weight: 400; letter-spacing: .3px; text-transform: none; color: var(--text-3); opacity: .7; margin-left: 6px; }
  .chart-svg { width: 100%; overflow: visible; }
  .legend { display: flex; gap: 14px; margin-top: 6px; }
  .leg { font-size: 10px; color: var(--text-3); display: flex; align-items: center; gap: 5px; }
  .leg::before { content:''; display:block; width:14px; height:2px; background:var(--c); }
  .leg-box-item { font-size: 10px; color: var(--text-3); display: flex; align-items: center; gap: 5px; }
  .leg-box { display: inline-block; width: 12px; height: 12px; border-radius: 2px; flex-shrink: 0; }

  .bar-chart { display: flex; flex-direction: column; gap: 6px; margin-top: 4px; }
  .bar-row { display: flex; align-items: center; gap: 8px; }
  .bar-row-btn {
    width: 100%; background: none; border: 1px solid transparent;
    border-radius: 6px; padding: 4px 6px; cursor: pointer;
    transition: border-color .15s, background .15s;
    position: relative;
  }
  .bar-row-btn:hover { background: var(--surface-2); border-color: var(--surface-border); }
  .bar-row-active { background: var(--surface-2); border-color: var(--surface-border); }
  .bar-active-dot {
    position: absolute; right: 6px; top: 50%; transform: translateY(-50%);
    width: 6px; height: 6px; border-radius: 50%;
  }
  .bar-label { font-size: 11px; color: var(--text-3); width: 105px; flex-shrink: 0; text-align: left; }
  .bar-track { flex: 1; height: 7px; background: var(--surface-3); border-radius: 99px; overflow: hidden; }
  .bar-fill { height: 100%; border-radius: 99px; transition: width .5s ease, opacity .2s; }
  .bar-val { font-size: 11px; font-weight: 600; width: 65px; text-align: right; font-variant-numeric: tabular-nums; }

  .chart-title-row { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
  .chart-title-row .chart-title { margin-bottom: 0; display: flex; align-items: center; gap: 8px; }
  .gallery-filter-badge {
    display: inline-flex; align-items: center; gap: 4px;
    font-size: 10px; font-weight: 600; padding: 2px 6px 2px 8px;
    border-radius: 99px; border: 1px solid; text-transform: none; letter-spacing: 0;
  }
  .filter-clear {
    background: none; border: none; cursor: pointer; font-size: 12px; line-height: 1;
    padding: 0 1px; opacity: .7; color: inherit;
  }
  .filter-clear:hover { opacity: 1; }

  .table { width: 100%; border-collapse: collapse; font-size: 12px; }
  .table th { text-align: left; font-size: 10px; text-transform: uppercase; letter-spacing: .5px; color: var(--text-3); padding: 5px 10px; border-bottom: 1px solid var(--surface-border); }
  .table td { padding: 9px 10px; border-bottom: 1px solid var(--surface-border); color: var(--text-1); }
  .table tr:last-child td { border-bottom: none; }
  .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-right: 7px; vertical-align: middle; }
  .mono { font-family: monospace; color: var(--text-2); }

  /* ── Gallery ── */
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
    border-color: var(--pc);
    color: var(--pc);
    font-weight: 700;
    opacity: 1;
    box-shadow: 0 0 0 1px color-mix(in srgb, var(--pc) 30%, transparent);
  }
  .filter-pill-active::before { opacity: 1; }
  .filter-pill-active::after { content: '✓'; font-size: 10px; margin-left: 2px; }
  .filter-pill-reset {
    padding: 4px 10px; border-radius: 99px; font-size: 11px; font-weight: 500;
    border: 1px solid var(--surface-border); color: var(--text-3);
    background: transparent; cursor: pointer; transition: color .15s, border-color .15s;
  }
  .filter-pill-reset:hover { color: var(--text-1); border-color: var(--text-3); }
  .gallery-layout { display: flex; gap: 16px; align-items: flex-start; }
  .gallery-main { flex: 1; min-width: 0; }
  .gallery-sidebar {
    flex-shrink: 0;
    display: flex; flex-direction: row;
    background: var(--bg-canvas);
    border: 1px solid var(--surface-border); border-radius: 8px;
    position: sticky; top: 16px; overflow: hidden;
  }
  .sidebar-handle {
    flex-shrink: 0; width: 28px;
    display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 5px;
    background: none; border: none; border-right: 1px solid var(--surface-border);
    cursor: pointer; color: var(--text-3); padding: 8px 0;
    transition: color .15s, background .15s;
  }
  .sidebar-handle:hover { color: var(--text-1); background: var(--surface-2); }
  .sidebar-body {
    width: 0; overflow: hidden;
    transition: width .2s ease;
  }
  .sidebar-body-open { width: 116px; }
  .sidebar-body-inner {
    width: 116px; padding: 10px;
    display: flex; flex-direction: column; gap: 12px;
  }
  .sidebar-badge {
    background: #e57373; color: #fff; font-size: 9px; font-weight: 700;
    border-radius: 999px; padding: 1px 5px; line-height: 1.4;
  }
  .sidebar-chevron { font-size: 14px; line-height: 1; transition: transform .2s; display: inline-block; }
  .sidebar-chevron.rotated { transform: rotate(180deg); }
  .sidebar-section { display: flex; flex-direction: column; gap: 5px; }
  .sidebar-label { font-size: 9px; text-transform: uppercase; letter-spacing: .06em; color: var(--text-3); margin-bottom: 2px; }
  .sidebar-pill {
    display: block; width: 100%; padding: 5px 8px; border-radius: 5px; font-size: 11px; font-weight: 500;
    border: 1px solid var(--surface-border); background: transparent; color: var(--text-2);
    cursor: pointer; text-align: left; transition: background .12s, color .12s, border-color .12s;
  }
  .sidebar-pill:hover { border-color: var(--sc); color: var(--sc); }
  .sidebar-pill-active { background: color-mix(in srgb, var(--sc) 15%, transparent); border-color: var(--sc); color: var(--sc); }
  .sidebar-clear { font-size: 10px; color: var(--text-3); background: none; border: none; cursor: pointer; text-align: left; padding: 0; margin-top: 2px; }
  .sidebar-clear:hover { color: var(--text-1); }
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
  .gallery-img-pair { display: flex; aspect-ratio: 2 / 1; }
  .gallery-half { width: 50%; height: 100%; object-fit: cover; display: block; flex-shrink: 0; }
  .sam3-gallery-card .gallery-img-wrap { aspect-ratio: 2 / 1; }
  .ad-gallery-card .gallery-img-wrap { aspect-ratio: 2 / 1; }
  .ad-gallery-card { cursor: zoom-in; }
  .gallery-img-wrap img:not(.gallery-half) { width: 100%; height: 100%; object-fit: cover; display: block; }
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
  .gallery-counts { display: flex; gap: 4px; font-size: 9px; font-weight: 600; font-family: monospace; }

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
  .lb-wide { max-width: min(96vw, 1400px); }
  .lb-img {
    width: 100%; aspect-ratio: 1;
    object-fit: contain; border-radius: 10px;
    box-shadow: 0 8px 48px rgba(0,0,0,0.7);
  }
  .lb-pair { display: flex; gap: 16px; width: 100%; }
  .lb-pair-col { display: flex; flex-direction: column; gap: 6px; flex: 1; min-width: 0; }
  .lb-pair-label { font-size: 10px; color: #888; text-transform: uppercase; letter-spacing: .6px; text-align: center; }
  .lb-pair .lb-img { aspect-ratio: 1; height: min(calc(90vh - 100px), 70vw); width: 100%; max-height: none; }
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
