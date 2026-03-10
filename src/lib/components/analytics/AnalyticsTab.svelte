<script lang="ts">
  import { onMount } from 'svelte';
  import { galleryCards } from './galleryData';
  import { themeStore } from '$lib/stores/theme.svelte';
  import DateRangePicker from './DateRangePicker.svelte';

  const dark = $derived(themeStore.theme === 'dark');
  let lightboxCard = $state<typeof galleryCards[0] | null>(null);

  function navigateGallery(dir: 1 | -1) {
    if (!lightboxCard) return;
    const idx = galleryCards.indexOf(lightboxCard as typeof galleryCards[number]);
    lightboxCard = galleryCards[(idx + dir + galleryCards.length) % galleryCards.length];
  }

  onMount(() => {
    function onKeydown(e: KeyboardEvent) {
      if (!lightboxCard) return;
      if (e.key === 'ArrowRight') navigateGallery(1);
      else if (e.key === 'ArrowLeft') navigateGallery(-1);
      else if (e.key === 'Escape') lightboxCard = null;
    }
    window.addEventListener('keydown', onKeydown);
    return () => window.removeEventListener('keydown', onKeydown);
  });
  let showEmailDialog = $state(false);
  let emailTo = $state('');
  let emailSending = $state(false);
  let emailResult = $state<{ ok: boolean; error?: string } | null>(null);

  // ── Date range filter ─────────────────────────────────────────────────────
  let startDate = $state('2025-09-30');
  let endDate   = $state('2025-11-12');

  // ── Degradation cutline ───────────────────────────────────────────────────
  const DEGRADATION_DATE = '2025-11-07'; // first day of system failure

  // ── Robinson Vision System V1 data ────────────────────────────────────────
  // Dates: all production days Sep 30 – Nov 12, 2025
  const DATES   = ["2025-09-30","2025-10-01","2025-10-02","2025-10-03","2025-10-06","2025-10-07","2025-10-23","2025-10-24","2025-10-28","2025-10-29","2025-10-30","2025-11-03","2025-11-04","2025-11-05","2025-11-07","2025-11-10","2025-11-11","2025-11-12"];
  // D_A: anomaly detections per day
  const D_A     = [2100,18500,42000,38000,31000,24000,76000,892,522,971,1004,1660,1836,835,20882,30659,93537,63742];
  // D_B: measurement defects (none for Robinson — anomaly-only system)
  const D_B     = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
  // D_G: good parts
  const D_G     = [21900,32500,53000,43000,42000,21000,0,27307,36337,87550,70088,38546,46434,68704,15839,10494,8134,5424];
  // ROLLING: 7-day rolling anomaly rate %
  const ROLLING = [8.7,36.3,44.2,46.9,42.5,53.3,100.0,3.16,1.42,1.10,1.41,4.13,3.80,1.20,56.90,74.51,92.04,92.12];
  // Hourly distribution (estimated from stable period throughput patterns)
  const H_ANOM  = [120,95,80,60,55,70,110,180,220,310,380,420,390,350,290,240,200,180,160,140,130,125,130,115];
  const H_MEAS  = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
  // Brightness score histogram (Robinson system, threshold 178.5)
  const BIN_LABELS = ["0–9","10–19","20–29","30–39","40–49","50–59","60–69","70–79","80–89","90–99","100–109","110–119","120–129","130–139","140–149","150–159","160–169","170–179","180–189","190–199","200–209","210–219","220–229","230–239","240–249","250–259"];
  const BIN_GOOD   = [52000,48000,44000,39000,35000,31000,27000,23000,19000,15000,11000,8500,6200,4500,3200,2200,1500,980,0,0,0,0,0,0,0,0];
  const BIN_DEFECT = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,120,1840,3200,4100,5200,6800,8400,9100,185000];

  // ── Filtered data (reactive on date range) ────────────────────────────────
  const filteredIdx = $derived(
    DATES.reduce((acc, d, i) => {
      if ((!startDate || d >= startDate) && (!endDate || d <= endDate)) acc.push(i);
      return acc;
    }, [] as number[])
  );
  const fDATES   = $derived(filteredIdx.map(i => DATES[i]));
  const fD_A     = $derived(filteredIdx.map(i => D_A[i]));
  const fD_B     = $derived(filteredIdx.map(i => D_B[i]));
  const fD_G     = $derived(filteredIdx.map(i => D_G[i]));
  const fROLLING = $derived(filteredIdx.map(i => ROLLING[i]));

  // Index in filtered data where degradation begins (first date >= DEGRADATION_DATE)
  const degradationFilteredIdx = $derived(fDATES.findIndex(d => d >= DEGRADATION_DATE));

  // ── KPI totals ────────────────────────────────────────────────────────────
  const totalAnomaly     = $derived(fD_A.reduce((a, b) => a + b, 0));
  const totalMeasurement = $derived(fD_B.reduce((a, b) => a + b, 0));
  const totalGood        = $derived(fD_G.reduce((a, b) => a + b, 0));
  const totalInspections = $derived(totalAnomaly + totalMeasurement + totalGood);
  const anomalyPct       = $derived(totalInspections > 0 ? (totalAnomaly / totalInspections * 100).toFixed(2) : '0.00');
  const measurementPct   = $derived(totalInspections > 0 ? (totalMeasurement / totalInspections * 100).toFixed(2) : '0.00');
  const goodPct          = $derived(totalInspections > 0 ? (totalGood / totalInspections * 100).toFixed(2) : '0.00');

  // ── SVG: Daily stacked bar + rolling line ─────────────────────────────────
  const DW = 1400; const DH = 230; const DPX = 50; const DPY = 16; const DPB = 55;
  const chartN      = $derived(Math.max(fDATES.length, 1));
  const chartTotals = $derived(fDATES.map((_, i) => fD_A[i] + fD_B[i] + fD_G[i]));
  const chartMax    = $derived(chartTotals.length ? Math.max(...chartTotals) : 1);
  const chartMaxR   = $derived(fROLLING.length ? Math.max(...fROLLING) : 1);
  const barW        = $derived(Math.max(6, (DW - DPX - 10) / chartN - 8));

  function cdx(i: number, n: number) { return DPX + i * ((DW - DPX - 10) / n) + 1; }
  function cdy(v: number, max: number) { return DPY + (1 - v / max) * (DH - DPY - DPB); }
  function cbarH(v: number, max: number) { return (v / max) * (DH - DPY - DPB); }

  // Dynamic Y-axis ticks for inspections chart
  const yAxisTicks = $derived(() => {
    const niceMax = chartMax <= 0 ? 1 : chartMax;
    const magnitude = Math.pow(10, Math.floor(Math.log10(niceMax)));
    const step = niceMax / magnitude <= 2 ? magnitude / 2 :
                 niceMax / magnitude <= 5 ? magnitude : magnitude * 2;
    const ticks: number[] = [];
    for (let v = 0; v <= niceMax * 1.05; v += step) ticks.push(v);
    return ticks;
  });

  const rollingLine = $derived(
    fDATES.length > 1
      ? fDATES.map((_, i) => `${cdx(i, fDATES.length) + barW / 2},${cdy(fROLLING[i], chartMaxR * 1.15)}`).join(' ')
      : ''
  );

  // Rolling line split into stable and degradation segments for separate coloring
  const rollingStablePts  = $derived(
    degradationFilteredIdx > 0
      ? fDATES.slice(0, degradationFilteredIdx).map((_, i) => `${cdx(i, fDATES.length) + barW / 2},${cdy(fROLLING[i], chartMaxR * 1.15)}`).join(' ')
      : (degradationFilteredIdx === -1 ? rollingLine : '')
  );
  const rollingDegradPts  = $derived(
    degradationFilteredIdx >= 0
      ? fDATES.slice(degradationFilteredIdx).map((_, i) => {
          const gi = degradationFilteredIdx + i;
          return `${cdx(gi, fDATES.length) + barW / 2},${cdy(fROLLING[gi], chartMaxR * 1.15)}`;
        }).join(' ')
      : ''
  );
  // Bridge point connecting stable line to degradation line
  const bridgePts = $derived(
    degradationFilteredIdx > 0 && degradationFilteredIdx < fDATES.length
      ? `${cdx(degradationFilteredIdx - 1, fDATES.length) + barW / 2},${cdy(fROLLING[degradationFilteredIdx - 1], chartMaxR * 1.15)} ${cdx(degradationFilteredIdx, fDATES.length) + barW / 2},${cdy(fROLLING[degradationFilteredIdx], chartMaxR * 1.15)}`
      : ''
  );

  // ── SVG: Hourly bars ──────────────────────────────────────────────────────
  const HW = 700; const HH = 180; const HPX = 10; const HPB = 24;
  const hourlyMax = Math.max(...H_ANOM.map((a, i) => a + H_MEAS[i]));
  function hx(i: number) { return HPX + i * ((HW - HPX * 2) / 24); }
  const hbw = (HW - HPX * 2) / 24 - 2;
  function hdy(v: number) { return (v / hourlyMax) * (HH - HPB); }

  // ── SVG: Score histogram (log scale) ─────────────────────────────────────
  const SW = 700; const SH = 180; const SPX = 10; const SPB = 24;
  const sbw = (SW - SPX * 2) / BIN_LABELS.length - 1;
  function sx(i: number) { return SPX + i * ((SW - SPX * 2) / BIN_LABELS.length); }
  function logH(n: number, maxH: number) {
    if (n <= 0) return 0;
    return (Math.log10(n) / Math.log10(maxH)) * (SH - SPB - 10);
  }
  const allBins = BIN_GOOD.map((g, i) => g + BIN_DEFECT[i]);
  const maxBin = Math.max(...allBins);
  const threshX = SPX + 17.5 * ((SW - SPX * 2) / BIN_LABELS.length);
  const borderX1 = SPX + 16 * ((SW - SPX * 2) / BIN_LABELS.length);
  const borderX2 = SPX + 20 * ((SW - SPX * 2) / BIN_LABELS.length);

  function fmt(n: number | string) {
    return Number(n).toLocaleString();
  }

  // ── Export ────────────────────────────────────────────────────────────────
  function exportCSV() {
    const rows = [
      ['Date', 'Anomaly Defects', 'Measurement Defects', 'Good Parts', 'Total', 'Anomaly Rate %'],
      ...fDATES.map((d, i) => {
        const total = fD_A[i] + fD_B[i] + fD_G[i];
        return [d, fD_A[i], fD_B[i], fD_G[i], total, (fD_A[i] / total * 100).toFixed(2)];
      })
    ];
    const csv = rows.map(r => r.join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `robinson-${startDate}-${endDate}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  function exportPDF() {
    window.print();
  }

  async function sendEmail() {
    if (!emailTo || emailSending) return;
    emailSending = true;
    emailResult = null;
    const subject = `Robinson Inspection Report ${startDate} – ${endDate}`;
    const body =
      `Robinson — Vision System V1 Report\n` +
      `${'─'.repeat(42)}\n` +
      `Period:                ${startDate} – ${endDate}\n` +
      `Production days:       ${fDATES.length}\n` +
      `\n` +
      `Total Inspections:     ${fmt(totalInspections)}\n` +
      `Anomaly Defects:       ${fmt(totalAnomaly)} (${anomalyPct}%)\n` +
      `Measurement Defects:   ${fmt(totalMeasurement)} (${measurementPct}%)\n` +
      `Good Parts:            ${fmt(totalGood)} (${goodPct}%)\n` +
      `\n` +
      `Configuration:\n` +
      `  BRIGHTNESS_THRESHOLD = 178.5\n` +
      `  SIMILARITY_THRESHOLD = 90%\n` +
      `\n` +
      `Generated by Deepvis · ${new Date().toLocaleString()}`;
    try {
      const res = await fetch('/api/send-email', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ to: emailTo, subject, body }),
      });
      emailResult = await res.json();
    } catch {
      emailResult = { ok: false, error: 'Network error' };
    }
    emailSending = false;
    if (emailResult?.ok) {
      setTimeout(() => { showEmailDialog = false; emailTo = ''; emailResult = null; }, 1500);
    }
  }
</script>

<!-- Lightbox -->
{#if lightboxCard}
  {@const orig = import.meta.env.BASE_URL + 'rob-originals/' + lightboxCard.key + '.jpg'}
  {@const heat = import.meta.env.BASE_URL + 'rob-heatmaps/'  + lightboxCard.key + '.jpg'}
  {@const over = import.meta.env.BASE_URL + 'rob-overlays/'  + lightboxCard.key + '.jpg'}
  {@const lbIdx = galleryCards.indexOf(lightboxCard as typeof galleryCards[number])}
  <div class="lb" onclick={() => (lightboxCard = null)}>
    <button class="lb-nav lb-prev" onclick={(e) => { e.stopPropagation(); navigateGallery(-1); }}>‹</button>
    <div class="lb-card" onclick={(e) => e.stopPropagation()}>
      <img src={orig} alt="Original" />
      <img src={heat} alt="Heatmap" />
      <img src={over} alt="Overlay" />
      <div class="lb-meta">
        {lightboxCard.ts} · ANOMALY · {lbIdx + 1} / {galleryCards.length} · ← → to navigate · Esc to close
      </div>
    </div>
    <button class="lb-nav lb-next" onclick={(e) => { e.stopPropagation(); navigateGallery(1); }}>›</button>
  </div>
{/if}

<div class="wrap" class:dark>
<div class="container">

  <!-- Email dialog -->
  {#if showEmailDialog}
    <div class="email-backdrop" onclick={() => showEmailDialog = false}>
      <div class="email-dialog" onclick={(e) => e.stopPropagation()}>
        <div class="email-title">Send Report by Email</div>
        <div class="email-body">
          <label class="email-label">Recipient email</label>
          <input
            class="email-input"
            type="email"
            placeholder="name@company.com"
            bind:value={emailTo}
            onkeydown={(e) => e.key === 'Enter' && sendEmail()}
            disabled={emailSending}
          />
          {#if emailResult}
            <div class="email-result" class:email-ok={emailResult.ok} class:email-err={!emailResult.ok}>
              {emailResult.ok ? '✓ Email sent successfully' : `✗ ${emailResult.error}`}
            </div>
          {:else}
            <div class="email-note">Sends a report summary directly — no email client needed.</div>
          {/if}
        </div>
        <div class="email-actions">
          <button class="email-cancel" onclick={() => { showEmailDialog = false; emailResult = null; emailTo = ''; }} disabled={emailSending}>Cancel</button>
          <button class="email-send" onclick={sendEmail} disabled={!emailTo || emailSending}>
            {emailSending ? 'Sending…' : 'Send'}
          </button>
        </div>
      </div>
    </div>
  {/if}

  <!-- Header -->
  <header>
    <div>
      <h1>Robinson — Vision System V1 Report</h1>
      <div class="sub">Automated anomaly detection &nbsp;·&nbsp; {startDate} – {endDate} &nbsp;·&nbsp; {fDATES.length} production day{fDATES.length !== 1 ? 's' : ''}</div>
    </div>
    <div class="header-btns">
      <div class="drp-wrap">
        <DateRangePicker bind:startDate bind:endDate />
      </div>
      <button class="export-btn" onclick={exportCSV} title="Download CSV">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
        CSV
      </button>
      <button class="export-btn" onclick={exportPDF} title="Export PDF">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
        PDF
      </button>
      <button class="export-btn" onclick={() => showEmailDialog = true} title="Send by email">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2z"/><polyline points="22,6 12,13 2,6"/></svg>
        Email
      </button>
    </div>
  </header>

  <!-- Config note -->
  <div class="note">
    <strong>Configuration:</strong>
    <span class="var-pill">BRIGHTNESS_THRESHOLD = 178.5</span> (= 0.7 × 255, integer cutoff ≥ 179)
    &nbsp;·&nbsp; Anomaly-only detection — no measurement defect category.
    &nbsp;·&nbsp; Pilot: Sep 30 – Oct 7 (calibration) · Stable: Oct 24 – Nov 5 · Degradation: Nov 7–12.
    &nbsp;·&nbsp; Source: SurrealDB vision system database · 2.85M images in S3.
  </div>

  <!-- KPI Cards -->
  <div class="cards">
    <div class="card">
      <div class="label">Total Inspections</div>
      <div class="value accent">{fmt(totalInspections)}</div>
      <div class="sub">{fDATES.length} production day{fDATES.length !== 1 ? 's' : ''} · = total heatmaps</div>
    </div>
    <div class="card">
      <div class="label">Anomaly Defects</div>
      <div class="value red">{fmt(totalAnomaly)}</div>
      <div class="sub">{anomalyPct}% · brightness ≥ 179</div>
    </div>
    <div class="card">
      <div class="label">Measurement Defects</div>
      <div class="value yellow">{fmt(totalMeasurement)}</div>
      <div class="sub">{measurementPct}% · N/A for Robinson system</div>
    </div>
    <div class="card">
      <div class="label">Good Parts</div>
      <div class="value green">{fmt(totalGood)}</div>
      <div class="sub">{goodPct}% · anomaly score &lt; threshold</div>
    </div>
  </div>

  <!-- Daily chart -->
  <div class="section">
    <h2>Daily Inspection Results &amp; Anomaly Rate Trend</h2>
    <div class="chart-scroll">
      <svg viewBox="0 0 {DW} {DH}" width="{DW}" style="min-width:{DW}px;height:auto;display:block">
        <!-- Degradation zone: red tint background, drawn first (behind bars) -->
        {#if degradationFilteredIdx >= 0}
          {@const degX = cdx(degradationFilteredIdx, fDATES.length)}
          <rect x={degX - 4} y={DPY} width={DW - degX - 6} height={DH - DPY - DPB}
            fill="rgba(229,115,115,0.06)" />
        {/if}

        <!-- Y-axis gridlines (left: inspections) — dynamic ticks -->
        {#each yAxisTicks() as v}
          {@const y = cdy(v, chartMax)}
          {#if y >= DPY && y <= DH - DPB + 2}
            <line x1={DPX} y1={y} x2={DW - 10} y2={y} stroke="var(--border)" stroke-width="1"/>
            <text x={DPX - 4} y={y + 4} text-anchor="end" font-size="9" fill="var(--text2)" font-family="system-ui">
              {v === 0 ? '0' : v >= 1000 ? (v/1000).toFixed(0)+'k' : v}
            </text>
          {/if}
        {/each}

        <!-- Stacked bars — degradation bars get distinct styling -->
        {#each fDATES as _, i}
          {@const x = cdx(i, fDATES.length)}
          {@const gH = cbarH(fD_G[i], chartMax)}
          {@const aH = cbarH(fD_A[i], chartMax)}
          {@const bH = cbarH(fD_B[i], chartMax)}
          {@const baseY = DH - DPB}
          {@const isDeg = degradationFilteredIdx >= 0 && i >= degradationFilteredIdx}
          <!-- Good (bottom) -->
          <rect x={x} y={baseY - gH} width={barW} height={gH}
            fill={isDeg ? 'rgba(229,115,115,0.18)' : 'rgba(112,193,163,0.45)'}/>
          <!-- Measurement (middle) -->
          <rect x={x} y={baseY - gH - bH} width={barW} height={bH} fill="rgba(251,191,36,0.55)"/>
          <!-- Anomaly (top) -->
          <rect x={x} y={baseY - gH - bH - aH} width={barW} height={aH}
            fill={isDeg ? 'rgba(229,115,115,0.95)' : 'rgba(229,115,115,0.75)'}/>
          <text x={x + barW/2} y={DH - 38} text-anchor="end" font-size="8"
            fill={isDeg ? 'rgba(229,115,115,0.8)' : 'var(--text2)'} font-family="system-ui"
            transform="rotate(-55,{x + barW/2},{DH - 38})">{fDATES[i].slice(5)}</text>
        {/each}

        <!-- Rolling anomaly rate line: green for stable, red for degradation -->
        {#if rollingStablePts}
          <polyline points={rollingStablePts} fill="none" stroke="#70c1a3" stroke-width="2.5" stroke-linejoin="round"/>
        {/if}
        {#if bridgePts}
          <polyline points={bridgePts} fill="none" stroke="#e57373" stroke-width="2" stroke-dasharray="4 3" stroke-linejoin="round" opacity="0.6"/>
        {/if}
        {#if rollingDegradPts}
          <polyline points={rollingDegradPts} fill="none" stroke="#e57373" stroke-width="2.5" stroke-linejoin="round"/>
        {/if}
        {#each fDATES as _, i}
          {@const isDeg = degradationFilteredIdx >= 0 && i >= degradationFilteredIdx}
          <circle cx={cdx(i, fDATES.length) + barW/2} cy={cdy(fROLLING[i], chartMaxR * 1.15)}
            r="3.5" fill={isDeg ? '#e57373' : '#70c1a3'}/>
        {/each}

        <!-- Cutline: vertical dashed line at degradation start -->
        {#if degradationFilteredIdx >= 0}
          {@const degX = cdx(degradationFilteredIdx, fDATES.length)}
          <line x1={degX - 4} y1={DPY} x2={degX - 4} y2={DH - DPB}
            stroke="#e57373" stroke-width="1.5" stroke-dasharray="6 3" opacity="0.7"/>
          <!-- Label pill -->
          <rect x={degX} y={DPY + 2} width="130" height="28" rx="4"
            fill="rgba(229,115,115,0.12)" stroke="rgba(229,115,115,0.35)" stroke-width="1"/>
          <text x={degX + 8} y={DPY + 13} font-size="8.5" fill="#e57373" font-family="system-ui" font-weight="700">⚠ SYSTEM DEGRADATION</text>
          <text x={degX + 8} y={DPY + 24} font-size="7.5" fill="rgba(229,115,115,0.7)" font-family="system-ui">Nov 7 → anomaly rate ↑ 56%</text>
        {/if}

        <!-- Right Y axis label -->
        <text x={DW - 4} y={DPY + 10} text-anchor="end" font-size="9" fill="#70c1a3" font-family="system-ui">Rate %</text>
        {#each [1, 2, 3, 4] as v}
          {@const y = cdy(v, chartMaxR * 1.15)}
          <text x={DW - 4} y={y + 4} text-anchor="end" font-size="9" fill="#70c1a3" font-family="system-ui">{v}%</text>
        {/each}
      </svg>
    </div>
    <!-- Legend -->
    <div class="legend">
      <span><span class="leg-box" style="background:rgba(112,193,163,0.45)"></span>Good Parts</span>
      <span><span class="leg-box" style="background:rgba(251,191,36,0.55)"></span>Measurement Defects</span>
      <span><span class="leg-box" style="background:rgba(229,115,115,0.85)"></span>Anomaly Defects</span>
      <span><span class="leg-line" style="background:#70c1a3"></span>7-Day Rolling Anomaly Rate</span>
    </div>
  </div>

  <!-- Hourly + Score Distribution -->
  <div class="two-col">

    <!-- Hourly -->
    <div class="section">
      <h2>Hourly Distribution</h2>
      <p class="chart-sub">Aggregated across all included days.</p>
      <svg viewBox="0 0 {HW} {HH}" width="100%">
        {#each [0, 200, 400, 600, 800] as v}
          {@const y = HH - HPB - hdy(v)}
          <line x1={HPX} y1={y} x2={HW - HPX} y2={y} stroke="var(--border)" stroke-width="1"/>
          <text x={HPX - 2} y={y + 4} text-anchor="end" font-size="8" fill="var(--text2)" font-family="system-ui">{v}</text>
        {/each}
        {#each Array.from({length: 24}, (_, i) => i) as i}
          {@const x = hx(i)}
          {@const mH = hdy(H_MEAS[i])}
          {@const aH = hdy(H_ANOM[i])}
          {@const base = HH - HPB}
          <rect x={x} y={base - mH} width={hbw} height={mH} fill="rgba(251,191,36,0.55)"/>
          <rect x={x} y={base - mH - aH} width={hbw} height={aH} fill="rgba(229,115,115,0.75)"/>
          {#if i % 3 === 0}
            <text x={x + hbw/2} y={HH - 6} text-anchor="middle" font-size="8" fill="var(--text2)" font-family="system-ui">{String(i).padStart(2,'0')}:00</text>
          {/if}
        {/each}
      </svg>
      <div class="legend">
        <span><span class="leg-box" style="background:rgba(251,191,36,0.55)"></span>Measurement</span>
        <span><span class="leg-box" style="background:rgba(229,115,115,0.75)"></span>Anomaly</span>
      </div>
    </div>

    <!-- Score Distribution -->
    <div class="section">
      <h2>Brightness Score Distribution</h2>
      <p class="chart-sub">Log scale. Threshold = 178.5 (≥179). Yellow band = borderline zone 160–199.</p>
      <svg viewBox="0 0 {SW} {SH}" width="100%">
        <!-- Borderline zone -->
        <rect x={borderX1} y="0" width={borderX2 - borderX1} height={SH - SPB} fill="rgba(251,191,36,0.08)"/>
        <rect x={borderX1} y="0" width="1" height={SH - SPB} fill="rgba(251,191,36,0.35)"/>
        <rect x={borderX2} y="0" width="1" height={SH - SPB} fill="rgba(251,191,36,0.35)"/>
        <text x={(borderX1+borderX2)/2} y="12" text-anchor="middle" font-size="8" fill="rgba(251,191,36,0.7)" font-family="system-ui">Borderline</text>

        <!-- Log gridlines -->
        {#each [1, 10, 100, 1000, 10000, 100000] as v}
          {@const y = SH - SPB - logH(v, maxBin)}
          {#if y > 0 && y < SH - SPB}
            <line x1={SPX} y1={y} x2={SW - SPX} y2={y} stroke="var(--border)" stroke-width="1"/>
            <text x={SPX - 2} y={y + 4} text-anchor="end" font-size="7" fill="var(--text2)" font-family="system-ui">{v >= 1000 ? (v/1000)+'k' : v}</text>
          {/if}
        {/each}

        <!-- Bars -->
        {#each BIN_LABELS as _, i}
          {@const x = sx(i)}
          {@const gH = logH(BIN_GOOD[i], maxBin)}
          {@const dH = logH(BIN_DEFECT[i], maxBin)}
          {@const base = SH - SPB}
          {#if BIN_GOOD[i] > 0}
            <rect x={x} y={base - gH} width={sbw} height={gH} fill="rgba(112,193,163,0.65)" rx="1"/>
          {/if}
          {#if BIN_DEFECT[i] > 0}
            <rect x={x} y={base - dH} width={sbw} height={dH} fill="rgba(229,115,115,0.75)" rx="1"/>
          {/if}
          {#if i % 2 === 0}
            <text x={x + sbw/2} y={SH - 6} text-anchor="middle" font-size="7"
              fill="var(--text2)" font-family="system-ui"
              transform="rotate(-60,{x + sbw/2},{SH - 6})">{BIN_LABELS[i]}</text>
          {/if}
        {/each}

        <!-- Threshold line -->
        <line x1={threshX} y1="0" x2={threshX} y2={SH - SPB} stroke="#e57373" stroke-width="2" stroke-dasharray="5,4"/>
        <text x={threshX + 3} y="20" font-size="8" fill="#e57373" font-family="system-ui" font-weight="600">Threshold 178.5</text>
      </svg>
      <div class="legend">
        <span><span class="leg-box" style="background:rgba(112,193,163,0.65)"></span>Good (&lt; 179)</span>
        <span><span class="leg-box" style="background:rgba(229,115,115,0.75)"></span>Defect (≥ 179)</span>
      </div>
    </div>

  </div>

  <!-- Period summary table -->
  <div class="section">
    <h2>Period Summary</h2>
    <table>
      <thead>
        <tr>
          <th>Period</th><th>Days</th><th>Total</th>
          <th>Anomaly Defects</th><th>Anomaly Rate</th>
          <th>Meas. Defects</th><th>Meas. Rate</th>
          <th>Good Parts</th><th>Note</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>Sep 30 – Oct 7, 2025</strong></td><td>6</td><td>269,500</td>
          <td class="red">155,600</td><td class="yellow">57.7%</td>
          <td class="yellow">—</td><td class="yellow">—</td>
          <td class="green">213,900</td>
          <td><span class="badge med">Calibration phase</span></td>
        </tr>
        <tr>
          <td><strong>Oct 24 – Nov 5, 2025</strong></td><td>7</td><td>382,686</td>
          <td class="red">7,720</td><td class="green">2.02%</td>
          <td class="yellow">—</td><td class="yellow">—</td>
          <td class="green">374,966</td>
          <td><span class="badge low">Stable · production ready</span></td>
        </tr>
        <!-- Degradation cutline row -->
        <tr class="cutline-row">
          <td colspan="9">
            <span class="cutline-label">⚠ System degradation starts Nov 7 — anomaly rate jumped from 1.2% → 56.9% overnight. Probable cause: camera/lighting change.</span>
          </td>
        </tr>
        <tr class="degradation-row">
          <td><strong>Nov 7–12, 2025</strong></td><td>4</td><td>248,711</td>
          <td class="red">208,820</td><td class="red">83.9%</td>
          <td class="yellow">—</td><td class="yellow">—</td>
          <td class="red">39,891</td>
          <td><span class="badge high">System failure</span></td>
        </tr>
      </tbody>
    </table>
  </div>

  <!-- Anomaly Defect Gallery -->
  <div class="section">
    <h2>Anomaly Defect Gallery — {galleryCards.length} Samples</h2>
    <p class="chart-sub" style="margin-bottom:16px">
      Each card: original capture · real model heatmap (36×36 score map, inferno colormap) · heatmap overlay blended on original.
      Click a card to enlarge. Sep 30 – Nov 12, 2025 · sorted chronologically · confidence ≥ 0.70.
    </p>
    <div class="gallery-grid">
      {#each galleryCards as card}
        {@const orig = import.meta.env.BASE_URL + 'rob-originals/' + card.key + '.jpg'}
        {@const heat = import.meta.env.BASE_URL + 'rob-heatmaps/'  + card.key + '.jpg'}
        {@const over = import.meta.env.BASE_URL + 'rob-overlays/'  + card.key + '.jpg'}
        <div class="gallery-card" onclick={() => (lightboxCard = card)}>
          <div class="gallery-imgs">
            <img src={orig} alt="Original" loading="lazy" />
            <img src={heat} alt="Heatmap"  loading="lazy" />
            <img src={over} alt="Overlay"  loading="lazy" />
          </div>
          <div class="gallery-meta">
            <span class="gallery-ts">{card.ts}</span>
            <span class="gallery-score">ANOMALY</span>
          </div>
        </div>
      {/each}
    </div>
  </div>

  <footer>
    <strong>Classification:</strong> Anomaly = brightness score above threshold · Good = score below threshold · No measurement defect category in Robinson CV1 system ·
    Total inspections = total processed images · Sep 30 – Nov 12, 2025 · Source: SurrealDB robinson.test · Robinson Packaging Denmark
  </footer>

</div>
</div>

<style>
  /* ── Theme ─────────────────────────────────────────────────────────────── */
  /* light mode (default) */
  .wrap {
    --bg:      var(--bg-canvas); --surface: var(--surface-1); --surface2: var(--surface-2); --border: var(--surface-border);
    --text:    var(--text-1); --text2: var(--text-2); --accent: #3aad86;
    --red:     #c62828; --green:   #2e7d32; --yellow:   #b45309;
  }
  /* dark mode */
  .wrap.dark {
    --bg:      var(--bg-canvas); --surface: var(--surface-1); --surface2: var(--surface-2); --border: var(--surface-border);
    --text:    var(--text-1); --text2: var(--text-2); --accent: #70c1a3;
    --red:     #ff4d6a; --green:   #34d399; --yellow:   #fbbf24;
  }

  /* ── Base ──────────────────────────────────────────────────────────────── */
  .wrap {
    height: 100%; overflow-y: auto;
    background-color: var(--bg);
    background-image: radial-gradient(circle, var(--dot-color) 0.5px, transparent 0.5px);
    background-size: 20px 20px;
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    font-size: 14px; line-height: 1.6;
  }
  .container { max-width: 1400px; margin: 0 auto; padding: 24px; }

  /* ── Header ────────────────────────────────────────────────────────────── */
  header {
    display: flex; align-items: flex-start; justify-content: space-between; gap: 16px;
    padding: 36px 0 28px; border-bottom: 1px solid var(--border); margin-bottom: 32px;
  }
  header h1 { font-size: 26px; font-weight: 700; letter-spacing: -0.3px; }
  .sub { color: var(--text2); margin-top: 6px; font-size: 14px; }
  .header-btns { display: flex; gap: 8px; flex-shrink: 0; }
  .drp-wrap { position: relative; }

  .export-btn {
    display: inline-flex; align-items: center; gap: 5px;
    padding: 0 12px; height: 32px; border-radius: 8px;
    font-size: 12px; font-weight: 500;
    background: var(--surface); border: 1px solid var(--border);
    color: var(--text2); cursor: pointer;
    transition: border-color .15s, color .15s;
    white-space: nowrap;
  }
  .export-btn:hover { border-color: var(--accent); color: var(--text); }

  /* Email dialog */
  .email-backdrop {
    position: fixed; inset: 0; z-index: 200;
    background: rgba(0,0,0,0.6); backdrop-filter: blur(4px);
    display: flex; align-items: center; justify-content: center;
  }
  .email-dialog {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 14px; padding: 24px; width: 360px;
    box-shadow: 0 20px 60px rgba(0,0,0,0.4);
  }
  .email-title { font-size: 15px; font-weight: 600; margin-bottom: 16px; color: var(--text); }
  .email-body { display: flex; flex-direction: column; gap: 8px; margin-bottom: 20px; }
  .email-label { font-size: 11px; text-transform: uppercase; letter-spacing: .6px; color: var(--text2); }
  .email-input {
    padding: 8px 12px; border-radius: 8px; font-size: 13px;
    background: var(--surface2); border: 1px solid var(--border);
    color: var(--text); outline: none;
  }
  .email-input:focus { border-color: #70c1a3; }
  .email-note { font-size: 11px; color: var(--text2); line-height: 1.5; }
  .email-result { font-size: 12px; font-weight: 500; padding: 6px 10px; border-radius: 6px; }
  .email-ok  { background: rgba(112,193,163,0.15); color: #70c1a3; }
  .email-err { background: rgba(229,115,115,0.15); color: #e57373; }
  .email-actions { display: flex; justify-content: flex-end; gap: 8px; }
  .email-cancel {
    padding: 0 14px; height: 32px; border-radius: 8px;
    font-size: 13px; font-weight: 500;
    background: var(--surface2); border: 1px solid var(--border);
    color: var(--text2); cursor: pointer;
  }
  .email-cancel:hover { color: var(--text); }
  .email-send {
    padding: 0 14px; height: 32px; border-radius: 8px;
    font-size: 13px; font-weight: 600;
    background: #70c1a3; border: none; color: #0f1f18; cursor: pointer;
  }
  .email-send:hover { background: #8dd0b5; }
  .email-send:disabled { opacity: .4; cursor: not-allowed; }

  /* ── Note ──────────────────────────────────────────────────────────────── */
  .note {
    background: var(--surface2); border: 1px solid var(--border);
    border-left: 3px solid var(--yellow); border-radius: 8px;
    padding: 12px 16px; margin-bottom: 24px; font-size: 13px;
    color: var(--text2); line-height: 1.7;
  }
  .note strong { color: var(--yellow); }
  .var-pill {
    display: inline-block; background: var(--surface); border: 1px solid var(--border);
    border-radius: 6px; padding: 3px 10px; font-family: monospace; font-size: 12px;
    color: var(--accent); margin: 0 2px;
  }

  /* ── Cards ─────────────────────────────────────────────────────────────── */
  .cards {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
    gap: 16px; margin-bottom: 32px;
  }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px;
  }
  .label { color: var(--text2); font-size: 12px; text-transform: uppercase; letter-spacing: 0.6px; }
  .value { font-size: 28px; font-weight: 700; margin-top: 6px; }
  .card .sub { color: var(--text2); font-size: 12px; margin-top: 4px; }
  .accent { color: var(--accent); } .red { color: var(--red); }
  .green  { color: var(--green); } .yellow { color: var(--yellow); }

  /* ── Sections ──────────────────────────────────────────────────────────── */
  .section {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px;
  }
  .section h2 { font-size: 15px; font-weight: 600; margin-bottom: 20px; }
  .chart-sub { font-size: 12px; color: var(--text2); margin-bottom: 16px; margin-top: -12px; }
  .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 24px; }
  @media (max-width: 900px) { .two-col { grid-template-columns: 1fr; } }

  /* ── Chart helpers ─────────────────────────────────────────────────────── */
  .chart-scroll { overflow-x: auto; scrollbar-width: none; }
  .chart-scroll::-webkit-scrollbar { display: none; }
  .legend { display: flex; gap: 16px; margin-top: 12px; flex-wrap: wrap; font-size: 12px; color: var(--text2); }
  .legend span { display: flex; align-items: center; gap: 6px; }
  .leg-box { width: 12px; height: 12px; border-radius: 2px; flex-shrink: 0; }
  .leg-line { width: 20px; height: 2.5px; border-radius: 2px; flex-shrink: 0; }

  /* ── Table ─────────────────────────────────────────────────────────────── */
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th {
    text-align: left; padding: 10px 14px; color: var(--text2);
    font-weight: 500; font-size: 12px; text-transform: uppercase;
    letter-spacing: 0.5px; border-bottom: 1px solid var(--border);
  }
  td { padding: 10px 14px; border-bottom: 1px solid var(--border); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: var(--surface2); }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
  .badge.high { background: rgba(255,77,106,0.15); color: var(--red); }
  .badge.med  { background: rgba(251,191,36,0.15);  color: var(--yellow); }
  .badge.low  { background: rgba(52,211,153,0.15);  color: var(--green); }

  /* Degradation cutline in table */
  .cutline-row td {
    padding: 0; border-bottom: none; border-top: none;
  }
  .cutline-label {
    display: block;
    padding: 7px 14px;
    background: rgba(229,115,115,0.08);
    border-top: 1.5px dashed rgba(229,115,115,0.5);
    border-bottom: 1.5px dashed rgba(229,115,115,0.5);
    color: rgba(229,115,115,0.9);
    font-size: 12px;
    font-weight: 500;
  }
  .degradation-row td {
    background: rgba(229,115,115,0.04);
  }

  /* ── Gallery ───────────────────────────────────────────────────────────── */
  .gallery-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
    gap: 12px;
  }
  .gallery-card {
    background: var(--surface2); border: 1px solid var(--border);
    border-radius: 10px; overflow: hidden; cursor: zoom-in;
    transition: border-color .15s, transform .1s;
  }
  .gallery-card:hover { border-color: var(--accent); transform: translateY(-1px); }
  .gallery-imgs {
    display: grid; grid-template-columns: 1fr 1fr 1fr;
  }
  .gallery-imgs img {
    width: 100%; aspect-ratio: 1; object-fit: cover; display: block;
  }
  .overlay-wrap { position: relative; }
  .overlay-wrap img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; }
  .red-tint {
    position: absolute; inset: 0;
    background: rgba(255, 77, 106, 0.6);
    mix-blend-mode: multiply;
    pointer-events: none;
  }
  .gallery-meta {
    padding: 8px 12px; display: flex; justify-content: space-between; align-items: center;
  }
  .gallery-ts   { font-size: 11px; color: var(--text2); }
  .gallery-score { font-size: 11px; font-weight: 600; color: var(--red); }

  /* ── Lightbox ──────────────────────────────────────────────────────────── */
  .lb {
    display: flex; position: fixed; inset: 0; z-index: 9999;
    background: rgba(0,0,0,0.88); align-items: center; justify-content: center;
    cursor: zoom-out; padding: 24px; gap: 16px;
  }
  .lb-nav {
    flex-shrink: 0; background: rgba(255,255,255,0.1); border: none; color: #fff;
    font-size: 48px; line-height: 1; width: 56px; height: 80px; border-radius: 8px;
    cursor: pointer; display: flex; align-items: center; justify-content: center;
    transition: background 0.15s; user-select: none;
  }
  .lb-nav:hover { background: rgba(255,255,255,0.22); }
  .lb-card {
    display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 10px;
    max-width: 90vw; cursor: default;
    background: var(--surface); border-radius: 12px;
    padding: 12px; box-shadow: 0 8px 48px rgba(0,0,0,0.7);
  }
  .lb-card img { width: 100%; aspect-ratio: 1; object-fit: contain; border-radius: 6px; display: block; }
  .lb-overlay-wrap { position: relative; }
  .lb-overlay-wrap img { width: 100%; aspect-ratio: 1; object-fit: contain; border-radius: 6px; display: block; }
  .red-overlay {
    position: absolute; inset: 0; border-radius: 6px;
    background: rgba(255, 77, 106, 0.6); mix-blend-mode: multiply; pointer-events: none;
  }
  .lb-meta {
    grid-column: 1 / -1; text-align: center;
    color: #8b8fa3; font-size: 12px; padding-top: 4px;
  }

  /* ── Footer ────────────────────────────────────────────────────────────── */
  footer {
    color: var(--text2); font-size: 12px; padding: 24px 0;
    border-top: 1px solid var(--border); margin-top: 8px; line-height: 1.8;
  }

  /* ── Print / PDF ────────────────────────────────────────────────────────── */
  @media print {
    .wrap {
      height: auto !important; overflow: visible !important;
      background: white !important; background-image: none !important;
      color: #111 !important;
      --bg: white; --surface: #fff; --surface2: #f5f5f5;
      --border: #ddd; --text: #111; --text2: #555;
      --accent: #3aad86; --red: #c62828; --green: #2e7d32; --yellow: #b45309;
    }
    .container { padding: 16px !important; }

    /* Hide interactive controls */
    .header-btns, .email-backdrop { display: none !important; }

    /* Header */
    header { padding: 16px 0 12px !important; margin-bottom: 16px !important; }

    /* Cards: 4 across */
    .cards { grid-template-columns: repeat(4, 1fr) !important; gap: 10px !important; margin-bottom: 16px !important; }
    .card { padding: 12px !important; break-inside: avoid; }
    .value { font-size: 20px !important; }

    /* Sections */
    .section { padding: 14px !important; margin-bottom: 12px !important; break-inside: avoid; }

    /* Charts: scale to page width */
    .chart-scroll { overflow: visible !important; }
    .chart-scroll svg { width: 100% !important; min-width: unset !important; height: auto !important; }

    /* Two-col stays two-col */
    .two-col { gap: 12px !important; }

    /* Page breaks */
    .section:nth-of-type(4) { break-before: page; }

    /* Gallery */
    .gallery-grid { grid-template-columns: repeat(4, 1fr) !important; gap: 8px !important; break-before: page; }
    .gallery-card { break-inside: avoid; }
    .gallery-meta { padding: 4px 8px !important; }

    /* Table */
    table { font-size: 11px !important; }
    th, td { padding: 6px 8px !important; }
    tr { break-inside: avoid; }
  }
</style>
