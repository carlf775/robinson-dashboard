<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import PlayIcon from '@lucide/svelte/icons/play';
  import SquareIcon from '@lucide/svelte/icons/square';
  import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
  import ShieldAlertIcon from '@lucide/svelte/icons/shield-alert';
  import BrainIcon from '@lucide/svelte/icons/brain';
  import ActivityIcon from '@lucide/svelte/icons/activity';
  import { createPipelineStore } from '$lib/stores/pipeline.svelte';
  import type { createProgramStore } from '$lib/stores/program.svelte';
  import type { createModulesStore } from '$lib/stores/modules.svelte';
  import { galleryCards } from '$lib/components/analytics/galleryData';

  let { store, modulesStore }: {
    store: ReturnType<typeof createProgramStore>;
    modulesStore?: ReturnType<typeof createModulesStore>;
  } = $props();

  const pipeline = createPipelineStore({ modulesStore });

  let selectedProgramId = $state<number | null>(null);
  let frameUrls = $state<Record<string, string>>({});
  let heatmapUrls = $state<Record<string, string>>({});
  let refreshTimer = $state<ReturnType<typeof setInterval> | null>(null);
  let frameCount = $state(0);
  let lastFrameCount = $state(0);
  let fps = $state(0);
  let fpsTimer = $state<ReturnType<typeof setInterval> | null>(null);

  // ── Mock mode ──────────────────────────────────────────────────────────────
  let mockActive = $state(false);
  let mockScore = $state(0.18);
  let mockFrames = $state(1247);
  let mockUnits = $state(145);
  let mockFps = $state(24);
  let mockAnomalous = $state(false);
  let mockDetections = $state(0);
  let mockElapsed = $state(0);
  let mockCardIndex = $state(0);
  let mockTimer = $state<ReturnType<typeof setInterval> | null>(null);
  let mockPaused = $state(false);

  // ── Real SAM3 inference ───────────────────────────────────────────────────
  type Sam3Result = { crown: number; thread: number; cavity_markers: number; underfilling: number; inferring: boolean; error: string | null };
  let sam3 = $state<Sam3Result>({ crown: 0, thread: 0, cavity_markers: 0, underfilling: 0, inferring: false, error: null });

  async function runSam3Inference(imageDataUrl: string) {
    sam3.inferring = true;
    sam3.error = null;
    try {
      const res = await fetch('/api/sam3/infer', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ image: imageDataUrl }),
      });
      const data = await res.json() as { prompt_results?: Array<{ echo: { text: string }; predictions: unknown[] }> };
      const counts: Record<string, number> = { crown: 0, thread: 0, cavity_markers: 0, underfilling: 0 };
      for (const pr of data.prompt_results ?? []) {
        counts[pr.echo.text] = pr.predictions?.length ?? 0;
      }
      sam3 = { ...counts as Sam3Result, inferring: false, error: null };
    } catch (e) {
      sam3.inferring = false;
      sam3.error = e instanceof Error ? e.message : 'Inference failed';
    }
  }

  let mockMeasX = $state(40.1);
  let mockMeasY = $state(39.9);
  const MEAS_TARGET = 40.0;
  const MEAS_TOL = 0.02;
  const measXOk = $derived(Math.abs(mockMeasX - MEAS_TARGET) <= MEAS_TOL);
  const measYOk = $derived(Math.abs(mockMeasY - MEAS_TARGET) <= MEAS_TOL);
  const overallOk = $derived(measXOk && measYOk);

  const mockCard = $derived(galleryCards[mockCardIndex % galleryCards.length]);

  const MOCK_NODES = [
    { id: 'mock-cam', label: 'GigE Camera', status: 'running' },
    { id: 'mock-sam', label: 'SAM3 Inference', status: 'inferring' },
  ];

  function fmtElapsed(s: number): string {
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    return `${h}h ${m}m ${sec}s`;
  }

  function startMock() {
    mockActive = true;
    mockFrames = 1247;
    mockUnits = 145;
    mockElapsed = 74;
    mockTimer = setInterval(() => {
      if (mockPaused) return;
      mockElapsed += 1;
      mockFrames += Math.floor(Math.random() * 3) + 1;
      if (Math.random() > 0.6) mockUnits += 1;
      mockFps = 22 + Math.floor(Math.random() * 5);
      // Advance card every 2 ticks
      if (mockElapsed % 2 === 0) {
        mockCardIndex = (mockCardIndex + 1) % galleryCards.length;
        // Use actual score from gallery card (0–255 scale → 0–1)
        mockScore = Math.min(1, galleryCards[mockCardIndex].score / 255);
        mockAnomalous = mockScore > 0.65;
        mockDetections = mockAnomalous ? Math.floor(mockScore * 8) : 0;
        // Simulate X/Y measurements with occasional out-of-tolerance
        mockMeasX = MEAS_TARGET + (Math.random() - 0.5) * 0.09;
        mockMeasY = MEAS_TARGET + (Math.random() - 0.5) * 0.09;
        // Run real SAM3 inference on the current card image
        if (!sam3.inferring) {
          runSam3Inference(galleryCards[mockCardIndex].orig);
        }
      }
    }, 1000);
  }

  function stopMock() {
    mockActive = false;
    if (mockTimer) { clearInterval(mockTimer); mockTimer = null; }
    sam3 = { crown: 0, thread: 0, cavity_markers: 0, underfilling: 0, inferring: false, error: null };
  }

  const isRunning = $derived(
    pipeline.status.state === 'running' || pipeline.status.state === 'starting'
  );
  const isStopping = $derived(pipeline.status.state === 'stopping');

  const inferenceNode = $derived(
    pipeline.status.nodes.find(n => n.node_type === 'sam3') ?? null
  );
  const cameraNode = $derived(
    pipeline.status.nodes.find(n => n.node_type === 'camera') ?? null
  );
  const primaryNode = $derived(inferenceNode ?? cameraNode);

  const score = $derived(inferenceNode?.score ?? 0);
  const scorePercent = $derived(Math.round(score * 100));
  const isAnomalous = $derived(inferenceNode?.is_anomalous ?? false);
  const detections = $derived(inferenceNode?.detection_count ?? 0);
  const totalFrames = $derived(primaryNode?.frame_count ?? 0);

  const scoreColor = $derived(
    score < 0.3 ? '#70c1a3' :
    score < 0.5 ? '#fbbf24' :
    score < 0.8 ? '#f97316' : '#e57373'
  );

  function refreshImages() {
    const ts = Date.now();
    const urls: Record<string, string> = {};
    const hmaps: Record<string, string> = {};
    for (const node of pipeline.status.nodes) {
      if (node.has_frame) urls[node.id] = `/api/pipeline/frame/${node.id}?t=${ts}`;
      if (node.has_heatmap) hmaps[node.id] = `/api/pipeline/heatmap/${node.id}?t=${ts}`;
    }
    frameUrls = urls;
    heatmapUrls = hmaps;
    frameCount = primaryNode?.frame_count ?? 0;
  }

  onMount(async () => {
    pipeline.connectWebSocket();
    pipeline.fetchStatus();

    // Refresh programs in case they weren't loaded yet
    if (store.programs.length === 0) {
      await store.fetchPrograms();
    }

    if (store.currentProgram) {
      selectedProgramId = store.currentProgram.id;
    } else if (store.programs.length > 0) {
      selectedProgramId = store.programs[0].id;
    }

    refreshTimer = setInterval(refreshImages, 250);
    fpsTimer = setInterval(() => {
      fps = Math.round((frameCount - lastFrameCount) * 4); // 4 ticks/sec → fps
      lastFrameCount = frameCount;
    }, 1000);
  });

  onDestroy(() => {
    pipeline.disconnect();
    if (refreshTimer) clearInterval(refreshTimer);
    if (fpsTimer) clearInterval(fpsTimer);
    if (mockTimer) clearInterval(mockTimer);
  });

  async function handleStart() {
    if (selectedProgramId == null) return;
    if (store.isDirty && store.currentProgram?.id === selectedProgramId) {
      await store.save();
    }
    pipeline.start(selectedProgramId);
  }

  function handleStop() {
    pipeline.stop();
  }

  function selectProgram(id: number) {
    if (!isRunning) selectedProgramId = id;
  }

  function formatTime(epoch: number | undefined): string {
    if (!epoch) return '--:--:--';
    return new Date(epoch * 1000).toLocaleTimeString('en-US', { hour12: false });
  }
</script>

<div class="run-wrap">

  <!-- ── Top bar: program tabs + controls ── -->
  <div class="topbar">
    <div class="tabs">
      <!-- Mock demo tab -->
      <button
        class="tab {mockActive ? 'tab-deployed' : ''}"
        onclick={() => mockActive ? stopMock() : startMock()}
        title="Demo preview"
      >
        <span class="tab-dot {mockActive ? 'dot-live' : ''}"></span>
        <span class="tab-name">Robinson Packaging · CV1 v1</span>
        {#if mockActive}
          <span class="tab-badge">LIVE</span>
        {:else}
          <span class="tab-badge" style="color:#555;background:rgba(255,255,255,0.04);border-color:rgba(145,145,145,0.15);">DEMO</span>
        {/if}
      </button>

      {#each store.programs as program (program.id)}
        {@const isActive = selectedProgramId === program.id}
        {@const isDeployed = isRunning && pipeline.status.program_id === program.id}
        <button
          class="tab {isActive ? 'tab-active' : ''} {isDeployed ? 'tab-deployed' : ''}"
          onclick={() => selectProgram(program.id)}
          disabled={isRunning && !isDeployed}
          title={program.name}
        >
          <span class="tab-dot {isDeployed ? 'dot-live' : ''}"></span>
          <span class="tab-name">{program.name}</span>
          {#if isDeployed}
            <span class="tab-badge">LIVE</span>
          {/if}
        </button>
      {/each}
    </div>

    <div class="controls">
      {#if pipeline.error}
        <span class="err-msg">{pipeline.error}</span>
      {/if}

      {#if mockActive}
        <button class="btn-pause" onclick={() => mockPaused = !mockPaused}>
          {#if mockPaused}
            <PlayIcon class="size-3.5" />
            Resume
          {:else}
            <SquareIcon class="size-3.5" />
            Pause
          {/if}
        </button>
        <button class="btn-stop" onclick={stopMock}>
          Stop Demo
        </button>
      {:else if isRunning || isStopping}
        <button class="btn-stop" onclick={handleStop} disabled={isStopping}>
          <SquareIcon class="size-3.5" />
          {isStopping ? 'Stopping…' : 'Stop'}
        </button>
      {:else}
        <button class="btn-start" onclick={handleStart} disabled={selectedProgramId == null}>
          <PlayIcon class="size-3.5" />
          Deploy
        </button>
      {/if}

      <div class="status-pill {mockActive ? 'status-running' : 'status-' + pipeline.status.state}">
        <span class="status-dot"></span>
        {mockActive ? 'running' : pipeline.status.state}
      </div>
    </div>
  </div>

  <!-- ── Main content ── -->
  {#if mockActive}
    {@const mockScorePercent = Math.round(mockScore * 100)}
    <div class="inspection-wrap">

      <!-- Batch Overview -->
      <div class="batch-card">
        <div class="batch-title">
          <ActivityIcon class="size-4" style="color:#70c1a3" />
          Current Batch Overview
        </div>

        <div class="batch-meta">
          <div class="batch-field">
            <div class="batch-field-label">Batch ID</div>
            <div class="batch-field-value">Robinson Packaging · Run #{Math.floor(mockFrames / 500) + 1}</div>
          </div>
          <div class="batch-field">
            <div class="batch-field-label">Article ID</div>
            <div class="batch-field-value">SAM3 v2 · Anomaly</div>
          </div>
          <div class="batch-field">
            <div class="batch-field-label">Time Since Start</div>
            <div class="batch-field-value mono">{fmtElapsed(mockElapsed)}</div>
          </div>
          <div class="batch-field">
            <div class="batch-field-label">Frame Rate</div>
            <div class="batch-field-value mono">{mockFps} fps</div>
          </div>
        </div>

        <div class="progress-row">
          <div class="progress-labels">
            <span>Batch Progress</span>
            <span class="mono" style="color:#919191">{mockUnits.toLocaleString()} / 10,000 units</span>
          </div>
          <div class="progress-track">
            <div class="progress-fill" style="width: {Math.min(100, mockUnits / 100)}%"></div>
          </div>
        </div>

        <button class="stop-acquisition" onclick={stopMock}>
          <SquareIcon class="size-4" />
          Stop Acquisition
        </button>
      </div>

      <!-- Current Inference -->
      <div class="inference-card">
        <div class="inference-title">Current Inference</div>

        <div class="inference-body">

          <!-- Camera feed -->
          <div class="inference-feed">
            <div class="card-views">
              <div class="card-view-wrap">
                <img src={mockCard.orig} alt="Original" class="card-view-img" />

                <!-- Solid measurement crosshair -->
                <svg class="meas-overlay" viewBox="0 0 100 100" preserveAspectRatio="none">
                  <line x1="5" y1="50" x2="95" y2="50"
                    stroke="{measXOk ? '#70c1a3' : '#e57373'}" stroke-width="0.5" />
                  <line x1="50" y1="5" x2="50" y2="95"
                    stroke="{measYOk ? '#70c1a3' : '#e57373'}" stroke-width="0.5" />
                  <circle cx="50" cy="50" r="1.5" fill="rgba(255,255,255,0.5)" />
                </svg>

                <!-- Large measurement overlay on first image -->
                <div class="img-meas-overlay {overallOk ? 'imo-ok' : 'imo-nok'}">
                  <div class="imo-verdict">
                    {#if overallOk}
                      <ShieldCheckIcon class="size-5" />
                    {:else}
                      <ShieldAlertIcon class="size-5" />
                    {/if}
                    <span>{overallOk ? 'OK' : 'NOK'}</span>
                  </div>
                  <div class="imo-axes">
                    <div class="imo-axis">
                      <span class="imo-axis-lbl">X</span>
                      <span class="imo-axis-val" style="color:{measXOk ? '#70c1a3' : '#e57373'}">{mockMeasX.toFixed(3)}</span>
                      <span class="imo-axis-unit">mm</span>
                      <span class="imo-badge {measXOk ? 'imob-ok' : 'imob-nok'}">{measXOk ? 'OK' : 'NOK'}</span>
                    </div>
                    <div class="imo-axis">
                      <span class="imo-axis-lbl">Y</span>
                      <span class="imo-axis-val" style="color:{measYOk ? '#70c1a3' : '#e57373'}">{mockMeasY.toFixed(3)}</span>
                      <span class="imo-axis-unit">mm</span>
                      <span class="imo-badge {measYOk ? 'imob-ok' : 'imob-nok'}">{measYOk ? 'OK' : 'NOK'}</span>
                    </div>
                  </div>
                </div>

                <div class="card-view-label">Original</div>
              </div>
              <div class="card-view-wrap">
                <img src={mockCard.heat} alt="Heatmap" class="card-view-img" />
                <div class="card-view-label">Heatmap</div>
              </div>
              <div class="card-view-wrap overlay-wrap">
                <img src={mockCard.heat} alt="Overlay" class="card-view-img" />
                <div class="card-view-tint" style="opacity:{mockAnomalous ? 0.55 : 0.2}"></div>
                <div class="card-view-label">Overlay</div>
              </div>
            </div>
          </div>

          <!-- Detection info panel (wider, no Pipeline) -->
          <div class="detection-info">
            <div class="detection-title">Measurement</div>

            <div class="meas-row">
              <div class="meas-axis-label">X Axis</div>
              <div class="meas-axis-value" style="color:{measXOk ? '#70c1a3' : '#e57373'}">{mockMeasX.toFixed(3)}<span class="meas-unit">mm</span></div>
              <div class="meas-badge {measXOk ? 'meas-ok' : 'meas-nok'}">{measXOk ? 'OK' : 'NOK'}</div>
            </div>
            <div class="meas-row">
              <div class="meas-axis-label">Y Axis</div>
              <div class="meas-axis-value" style="color:{measYOk ? '#70c1a3' : '#e57373'}">{mockMeasY.toFixed(3)}<span class="meas-unit">mm</span></div>
              <div class="meas-badge {measYOk ? 'meas-ok' : 'meas-nok'}">{measYOk ? 'OK' : 'NOK'}</div>
            </div>
            <div class="meas-target">Target: {MEAS_TARGET.toFixed(1)} mm ± {MEAS_TOL.toFixed(2)} mm</div>

            <div class="detection-divider"></div>
            <div class="detection-title" style="font-size:12px;margin-bottom:10px;display:flex;align-items:center;gap:8px">
              SAM3 Inference
              {#if sam3.inferring}<span class="sam3-inferring">inferring…</span>{/if}
            </div>

            {#if sam3.error}
              <div class="sam3-error">{sam3.error}</div>
            {:else}
              {@const sam3Total = sam3.crown + sam3.thread + sam3.cavity_markers + sam3.underfilling}
              <div class="detection-row">
                <span class="detection-label">Status</span>
                <span class="detection-value {sam3Total > 0 ? 'dv-anomaly' : 'dv-ok'}">
                  {#if sam3Total > 0}<ShieldAlertIcon class="size-3.5" /> DEFECT
                  {:else}<ShieldCheckIcon class="size-3.5" /> PASS{/if}
                </span>
              </div>
              <div class="detection-row">
                <span class="detection-label">Crown</span>
                <span class="detection-value mono" style="color:{sam3.crown > 0 ? '#e57373' : '#70c1a3'}">{sam3.crown}</span>
              </div>
              <div class="detection-row">
                <span class="detection-label">Thread</span>
                <span class="detection-value mono" style="color:{sam3.thread > 0 ? '#e57373' : '#70c1a3'}">{sam3.thread}</span>
              </div>
              <div class="detection-row">
                <span class="detection-label">Cavity Markers</span>
                <span class="detection-value mono" style="color:{sam3.cavity_markers > 0 ? '#e57373' : '#70c1a3'}">{sam3.cavity_markers}</span>
              </div>
              <div class="detection-row">
                <span class="detection-label">Underfilling</span>
                <span class="detection-value mono" style="color:{sam3.underfilling > 0 ? '#e57373' : '#70c1a3'}">{sam3.underfilling}</span>
              </div>
            {/if}
            <div class="detection-row">
              <span class="detection-label">Frames</span>
              <span class="detection-value mono">{mockFrames.toLocaleString()}</span>
            </div>
          </div>
        </div>
      </div>
    </div>

  {:else if isRunning && primaryNode}
    <div class="live-layout">

      <!-- Primary feed -->
      <div class="feed-wrap">
        {#if primaryNode.id && frameUrls[primaryNode.id]}
          <img
            src={frameUrls[primaryNode.id]}
            alt="Live feed"
            class="feed-img"
          />
          {#if inferenceNode && heatmapUrls[inferenceNode.id]}
            <img
              src={heatmapUrls[inferenceNode.id]}
              alt="Heatmap"
              class="feed-heatmap"
            />
          {/if}
        {:else}
          <div class="feed-placeholder">
            <ActivityIcon class="size-8 text-zinc-600" />
            <span>Waiting for frames…</span>
          </div>
        {/if}

        <!-- Bottom overlay: timestamp + fps -->
        <div class="feed-overlay-bottom">
          <span>{formatTime(primaryNode.last_frame_time)}</span>
          <span class="fps-badge">{fps} fps</span>
        </div>
      </div>

      <!-- Stats sidebar -->
      <div class="stats-panel">

        <!-- Score -->
        {#if inferenceNode}
          <div class="stat-card">
            <div class="stat-label">Anomaly Score</div>
            <div class="stat-value" style="color: {scoreColor}; font-size: 2.8rem;">
              {scorePercent}<span style="font-size:1rem;opacity:.6">%</span>
            </div>
            <div class="verdict {isAnomalous ? 'verdict-fail' : 'verdict-pass'}">
              {#if isAnomalous}
                <ShieldAlertIcon class="size-4" />
                ANOMALY
              {:else}
                <ShieldCheckIcon class="size-4" />
                PASS
              {/if}
            </div>
          </div>

          {#if detections > 0}
            <div class="stat-card">
              <div class="stat-label">Detections</div>
              <div class="stat-value">{detections}</div>
            </div>
          {/if}
        {/if}

        <!-- Frame stats -->
        <div class="stat-card">
          <div class="stat-label">Frames Processed</div>
          <div class="stat-value" style="font-size:1.6rem;">{totalFrames.toLocaleString()}</div>
        </div>

        <div class="stat-card">
          <div class="stat-label">Frame Rate</div>
          <div class="stat-value" style="font-size:1.6rem;">{fps} <span style="font-size:.9rem;opacity:.5">fps</span></div>
        </div>

        <!-- Node statuses -->
        <div class="node-list">
          <div class="stat-label" style="margin-bottom:8px;">Pipeline Nodes</div>
          {#each pipeline.status.nodes as node (node.id)}
            <div class="node-row">
              <BrainIcon class="size-3.5 shrink-0" style="color: #70c1a3" />
              <span class="node-label">{node.label}</span>
              <span class="node-status node-status-{node.status}">{node.status}</span>
            </div>
          {/each}
        </div>
      </div>
    </div>

  {:else if pipeline.status.state === 'starting'}
    <div class="idle-state" style="flex:1">
      <div class="spinner"></div>
      <span>Starting pipeline…</span>
    </div>

  {:else}
    <!-- Idle: show program cards -->
    <div class="idle-scroll">
        <div class="idle-header">
          <p class="idle-hint">Select a configuration and hit <strong>Deploy</strong></p>
        </div>
        <div class="idle-grid">
          <!-- Mock demo card (always visible) -->
          <button
            class="program-card {mockActive ? 'program-card-selected' : ''}"
            onclick={() => mockActive ? stopMock() : startMock()}
          >
            <div class="program-card-icon" style="color:#70c1a3">
              <BrainIcon class="size-5" />
            </div>
            <div class="program-card-name">Robinson Packaging · CV1 v1</div>
            <div class="program-card-sub">Demo · Anomaly Detection</div>
            {#if mockActive}
              <div class="program-card-badge">Live</div>
            {:else}
              <div class="program-card-badge" style="color:#555;background:rgba(255,255,255,0.04);border-color:rgba(145,145,145,0.15);">Demo</div>
            {/if}
          </button>

          {#each store.programs as program (program.id)}
            {@const isSelected = selectedProgramId === program.id}
            <button
              class="program-card {isSelected ? 'program-card-selected' : ''}"
              onclick={() => selectProgram(program.id)}
            >
              <div class="program-card-icon">
                <BrainIcon class="size-5" />
              </div>
              <div class="program-card-name">{program.name}</div>
              <div class="program-card-sub">AI Configuration</div>
              {#if isSelected}
                <div class="program-card-badge">Selected</div>
              {/if}
            </button>
          {/each}
        </div>
    </div>
  {/if}
</div>

<style>
  .run-wrap {
    height: 100%;
    display: flex;
    flex-direction: column;
    background-color: var(--bg-canvas);
    background-image: radial-gradient(circle, var(--dot-color) 0.5px, transparent 0.5px);
    background-size: 20px 20px;
    color: var(--foreground);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    overflow: hidden;
  }

  /* ── Top bar ── */
  .topbar {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 0 16px;
    height: 44px;
    background: var(--topbar-bg);
    border-bottom: 1px solid var(--surface-border);
    backdrop-filter: blur(8px);
    flex-shrink: 0;
    overflow-x: auto;
    scrollbar-width: none;
  }
  .topbar::-webkit-scrollbar { display: none; }

  .tabs {
    display: flex;
    gap: 2px;
    flex: 1;
    min-width: 0;
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0 12px;
    height: 32px;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 500;
    color: var(--text-2);
    background: transparent;
    border: 1px solid transparent;
    cursor: pointer;
    white-space: nowrap;
    transition: color .15s, background .15s, border-color .15s;
  }
  .tab:hover:not(:disabled) { color: var(--text-1); background: var(--surface-border); }
  .tab:disabled { opacity: 0.4; cursor: not-allowed; }
  .tab-active { color: var(--text-1); background: var(--surface-2); border-color: var(--surface-border); }
  .tab-deployed { border-color: rgba(112,193,163,0.4); color: #70c1a3; }

  .tab-dot {
    width: 6px; height: 6px;
    border-radius: 50%;
    background: var(--surface-3);
    flex-shrink: 0;
  }
  .dot-live {
    background: #70c1a3;
    box-shadow: 0 0 6px rgba(112,193,163,0.6);
    animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }

  .tab-name { max-width: 120px; overflow: hidden; text-overflow: ellipsis; }
  .tab-badge {
    font-size: 9px; font-weight: 700; letter-spacing: .8px;
    color: #70c1a3; background: rgba(112,193,163,0.12);
    border: 1px solid rgba(112,193,163,0.3);
    border-radius: 4px; padding: 1px 5px;
  }

  /* ── Controls ── */
  .controls { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }

  .err-msg { font-size: 11px; color: #e57373; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  .btn-start, .btn-stop {
    display: flex; align-items: center; gap: 5px;
    padding: 0 12px; height: 28px; border-radius: 6px;
    font-size: 12px; font-weight: 600; cursor: pointer;
    border: none; transition: opacity .15s, background .15s;
  }
  .btn-pause {
    display: flex; align-items: center; gap: 5px;
    padding: 0 12px; height: 28px; border-radius: 6px;
    font-size: 12px; font-weight: 600; cursor: pointer;
    background: var(--surface-2); border: 1px solid var(--surface-border);
    color: var(--text-1); transition: background .15s;
  }
  .btn-pause:hover { background: var(--surface-3); }
  .btn-start { background: #70c1a3; color: #0f1f18; }
  .btn-start:hover:not(:disabled) { background: #8dd0b5; }
  .btn-start:disabled { opacity: 0.4; cursor: not-allowed; }
  .btn-stop { background: rgba(229,115,115,0.12); color: #e57373; border: 1px solid rgba(229,115,115,0.3); }
  .btn-stop:hover:not(:disabled) { background: rgba(229,115,115,0.22); }
  .btn-stop:disabled { opacity: 0.5; cursor: not-allowed; }

  .status-pill {
    display: flex; align-items: center; gap: 5px;
    padding: 0 8px; height: 22px; border-radius: 99px;
    font-size: 10px; font-weight: 600; letter-spacing: .5px; text-transform: capitalize;
    background: var(--surface-2); border: 1px solid var(--surface-border);
    color: var(--text-2);
  }
  .status-dot {
    width: 5px; height: 5px; border-radius: 50%;
    background: currentColor;
  }
  .status-running { color: #70c1a3; }
  .status-starting, .status-stopping { color: #fbbf24; }
  .status-error { color: #e57373; }

  /* ── Live layout ── */
  .live-layout {
    flex: 1;
    display: flex;
    min-height: 0;
    overflow: hidden;
  }

  /* Feed */
  .feed-wrap {
    flex: 1;
    position: relative;
    background: #000;
    display: flex;
    align-items: center;
    justify-content: center;
    min-width: 0;
  }
  .feed-img {
    width: 100%; height: 100%;
    object-fit: contain;
    display: block;
  }
  .feed-heatmap {
    position: absolute; inset: 0;
    width: 100%; height: 100%;
    object-fit: contain;
    pointer-events: none;
  }
  .feed-placeholder {
    display: flex; flex-direction: column; align-items: center; gap: 12px;
    color: var(--text-3); font-size: 13px;
  }
  .feed-overlay-bottom {
    position: absolute; bottom: 0; left: 0; right: 0;
    display: flex; justify-content: space-between; align-items: center;
    padding: 6px 12px;
    background: linear-gradient(transparent, rgba(0,0,0,0.7));
    font-size: 11px; font-family: monospace; color: rgba(255,255,255,0.5);
  }
  .fps-badge {
    background: rgba(112,193,163,0.15);
    border: 1px solid rgba(112,193,163,0.25);
    color: #70c1a3; padding: 1px 7px; border-radius: 4px;
    font-size: 10px; font-weight: 600;
  }

  /* Stats panel */
  .stats-panel {
    width: 220px;
    flex-shrink: 0;
    background: var(--surface-1);
    border-left: 1px solid var(--surface-border);
    display: flex;
    flex-direction: column;
    gap: 1px;
    overflow-y: auto;
    scrollbar-width: none;
  }
  .stats-panel::-webkit-scrollbar { display: none; }

  .stat-card {
    padding: 16px 18px;
    border-bottom: 1px solid var(--surface-border);
  }
  .stat-label {
    font-size: 10px; text-transform: uppercase; letter-spacing: .8px;
    color: var(--text-3); font-weight: 500; margin-bottom: 6px;
  }
  .stat-value {
    font-size: 2rem; font-weight: 700; line-height: 1;
    color: var(--text-1); font-variant-numeric: tabular-nums;
  }

  .verdict {
    display: inline-flex; align-items: center; gap: 5px;
    margin-top: 10px; padding: 4px 10px; border-radius: 99px;
    font-size: 11px; font-weight: 700; letter-spacing: .5px;
  }
  .verdict-pass { background: rgba(112,193,163,0.12); color: #70c1a3; border: 1px solid rgba(112,193,163,0.25); }
  .verdict-fail { background: rgba(229,115,115,0.12); color: #e57373; border: 1px solid rgba(229,115,115,0.25); }

  .node-list { padding: 14px 18px; }
  .node-row {
    display: flex; align-items: center; gap: 7px;
    padding: 5px 0; border-bottom: 1px solid var(--surface-border);
    font-size: 11px;
  }
  .node-row:last-child { border-bottom: none; }
  .node-label { flex: 1; color: var(--text-2); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .node-status { font-size: 10px; font-weight: 600; text-transform: capitalize; flex-shrink: 0; }
  .node-status-running { color: #70c1a3; }
  .node-status-inferring { color: #a78bfa; }
  .node-status-idle, .node-status-stopped { color: var(--text-3); }
  .node-status-error { color: #e57373; }

  /* ── Idle state ── */
  .idle-scroll {
    flex: 1; overflow-y: auto; scrollbar-width: none;
  }
  .idle-scroll::-webkit-scrollbar { display: none; }

  .idle-header {
    padding: 28px 28px 0;
  }
  .idle-hint {
    font-size: 12px; color: var(--text-3);
  }
  .idle-hint strong { color: #70c1a3; font-weight: 600; }

  .idle-state {
    flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center;
    height: 100%; gap: 14px; color: var(--text-3); font-size: 13px;
  }
  .spinner {
    width: 28px; height: 28px; border-radius: 50%;
    border: 2px solid rgba(112,193,163,0.2);
    border-top-color: #70c1a3;
    animation: spin .8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ── Program cards (idle select) ── */
  .idle-grid {
    padding: 16px 28px 32px;
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 12px;
    align-content: start;
    overflow-y: auto;
  }
  .program-card {
    background: var(--surface-1);
    border: 1px solid var(--surface-border);
    border-radius: 10px;
    padding: 20px 16px;
    cursor: pointer;
    text-align: left;
    transition: border-color .15s, background .15s;
    position: relative;
  }
  .program-card:hover { border-color: var(--surface-border-hover); background: var(--surface-2); }
  .program-card-selected { border-color: rgba(112,193,163,0.4); background: rgba(112,193,163,0.04); }

  .program-card-icon { color: #70c1a3; margin-bottom: 10px; }
  .program-card-name { font-size: 13px; font-weight: 600; color: var(--text-1); margin-bottom: 3px; }
  .program-card-sub { font-size: 11px; color: var(--text-3); }
  .program-card-badge {
    position: absolute; top: 10px; right: 10px;
    font-size: 9px; font-weight: 700; color: #70c1a3;
    background: rgba(112,193,163,0.1); border: 1px solid rgba(112,193,163,0.25);
    border-radius: 4px; padding: 1px 6px; letter-spacing: .5px;
  }

  /* ── Inspection layout ── */
  .inspection-wrap {
    flex: 1; overflow-y: auto; padding: 20px 24px;
    display: flex; flex-direction: column; gap: 16px;
    scrollbar-width: none;
  }
  .inspection-wrap::-webkit-scrollbar { display: none; }

  .batch-card, .inference-card {
    background: var(--surface-1);
    border: 1px solid var(--surface-border);
    border-radius: 10px;
    padding: 20px 24px;
  }

  .batch-title, .inference-title {
    display: flex; align-items: center; gap: 8px;
    font-size: 14px; font-weight: 600; color: var(--text-1);
    margin-bottom: 16px;
  }

  .batch-meta {
    display: grid; grid-template-columns: repeat(4, 1fr);
    gap: 16px; margin-bottom: 16px;
  }
  .batch-field-label {
    font-size: 10px; text-transform: uppercase; letter-spacing: .7px;
    color: var(--text-3); margin-bottom: 4px;
  }
  .batch-field-value { font-size: 13px; font-weight: 600; color: var(--text-1); }
  .batch-field-value.mono { font-family: monospace; }
  .mono { font-family: monospace; }

  .progress-row { margin-bottom: 16px; }
  .progress-labels {
    display: flex; justify-content: space-between;
    font-size: 11px; color: var(--text-3); margin-bottom: 6px;
  }
  .progress-track {
    height: 4px; background: var(--surface-3);
    border-radius: 99px; overflow: hidden;
  }
  .progress-fill {
    height: 100%; background: #70c1a3;
    border-radius: 99px; transition: width .5s ease;
  }

  .stop-acquisition {
    display: flex; align-items: center; justify-content: center; gap: 8px;
    width: 100%; padding: 10px;
    background: rgba(229,115,115,0.12);
    border: 1px solid rgba(229,115,115,0.3);
    border-radius: 8px;
    color: #e57373; font-size: 13px; font-weight: 600;
    cursor: pointer; transition: background .15s;
  }
  .stop-acquisition:hover { background: rgba(229,115,115,0.22); }

  /* ── Measurement overlay on first image ── */
  .img-meas-overlay {
    position: absolute; bottom: 10px; left: 10px;
    display: flex; flex-direction: column; gap: 6px;
    background: rgba(12, 16, 14, 0.82);
    backdrop-filter: blur(6px);
    border: 1px solid rgba(145,145,145,0.18);
    border-radius: 8px;
    padding: 10px 12px;
    pointer-events: none;
    min-width: 130px;
  }

  .imo-verdict {
    display: flex; align-items: center; gap: 6px;
    font-size: 28px; font-weight: 900; letter-spacing: 2px; line-height: 1;
  }
  .imo-ok  .imo-verdict { color: #70c1a3; }
  .imo-nok .imo-verdict { color: #e57373; }

  .imo-axes { display: flex; flex-direction: column; gap: 4px; }

  .imo-axis {
    display: flex; align-items: baseline; gap: 5px;
  }
  .imo-axis-lbl {
    font-size: 10px; font-weight: 700; text-transform: uppercase;
    letter-spacing: 1px; color: rgba(255,255,255,0.45); width: 12px; flex-shrink: 0;
  }
  .imo-axis-val {
    font-size: 18px; font-weight: 800; font-variant-numeric: tabular-nums; line-height: 1;
  }
  .imo-axis-unit {
    font-size: 10px; color: rgba(255,255,255,0.45);
  }
  .imo-badge {
    font-size: 10px; font-weight: 800; letter-spacing: .8px;
    padding: 2px 7px; border-radius: 3px; margin-left: 2px;
  }
  .imob-ok  { background: rgba(112,193,163,0.25); color: #70c1a3; }
  .imob-nok { background: rgba(229,115,115,0.25); color: #e57373; }

  /* ── Measurement overlay on image ── */
  .meas-overlay {
    position: absolute; inset: 0; width: 100%; height: 100%;
    pointer-events: none;
  }

  /* ── Measurement panel rows ── */
  .meas-row {
    display: flex; align-items: center; gap: 8px;
    padding: 10px 0; border-bottom: 1px solid var(--surface-border);
  }
  .meas-axis-label {
    font-size: 11px; text-transform: uppercase; letter-spacing: .7px;
    color: var(--text-3); width: 44px; flex-shrink: 0;
  }
  .meas-axis-value {
    font-size: 28px; font-weight: 800; line-height: 1; flex: 1;
    font-variant-numeric: tabular-nums;
  }
  .meas-unit { font-size: 12px; font-weight: 500; opacity: .6; margin-left: 3px; }
  .meas-badge {
    font-size: 13px; font-weight: 800; letter-spacing: 1px;
    padding: 4px 12px; border-radius: 5px; flex-shrink: 0;
  }
  .meas-ok  { background: rgba(112,193,163,0.15); color: #70c1a3; border: 1px solid rgba(112,193,163,0.3); }
  .meas-nok { background: rgba(229,115,115,0.15); color: #e57373; border: 1px solid rgba(229,115,115,0.3); }
  .meas-target {
    font-size: 10px; color: var(--text-3); padding: 6px 0 2px;
  }

  /* Inference section */
  .inference-body {
    display: flex; gap: 20px; min-height: 0;
  }
  .inference-feed {
    flex: 1; position: relative; background: #000;
    border-radius: 8px; overflow: hidden;
    min-height: 260px;
  }

  .detection-info {
    width: 280px; flex-shrink: 0;
    display: flex; flex-direction: column; gap: 0;
  }
  .detection-title {
    font-size: 13px; font-weight: 600; color: var(--text-1);
    margin-bottom: 16px;
  }
  .detection-row {
    display: flex; align-items: center; justify-content: space-between;
    padding: 8px 0;
    border-bottom: 1px solid var(--surface-border);
    font-size: 12px;
  }
  .detection-label { color: var(--text-3); }
  .detection-value {
    font-weight: 600; color: var(--text-1);
    display: flex; align-items: center; gap: 4px;
  }
  .dv-ok { color: #70c1a3; }
  .dv-anomaly { color: #e57373; }
  .detection-divider { margin: 12px 0; border-top: 1px solid var(--surface-border); }
  .detection-nodes { display: flex; flex-direction: column; }

  /* ── Gallery card views ── */
  .card-views {
    display: grid; grid-template-columns: 1fr 1fr 1fr;
    height: 100%; gap: 0;
  }
  .card-view-wrap {
    position: relative; overflow: hidden; background: #000;
  }
  .card-view-wrap + .card-view-wrap { border-left: 1px solid rgba(145,145,145,0.12); }
  .card-view-img {
    width: 100%; height: 100%; object-fit: cover; display: block;
  }
  .card-view-label {
    position: absolute; bottom: 6px; left: 8px;
    font-size: 9px; font-weight: 600; text-transform: uppercase; letter-spacing: .6px;
    color: rgba(255,255,255,0.45);
  }
  .overlay-wrap { position: relative; }
  .card-view-tint {
    position: absolute; inset: 0;
    background: rgba(229, 115, 115, 0.6);
    mix-blend-mode: multiply;
    pointer-events: none;
    transition: opacity .4s;
  }

  /* ── Mock feed ── */
  .mock-feed {
    width: 100%; height: 100%;
    background: #080c0b;
    position: relative;
    display: flex; align-items: center; justify-content: center;
    overflow: hidden;
  }
  .mock-part {
    width: min(55%, 340px); aspect-ratio: 1;
    border: 1px solid rgba(112,193,163,0.3);
    border-radius: 50%;
    display: flex; align-items: center; justify-content: center;
    transition: border-color .4s;
    position: relative;
  }
  .mock-part-inner {
    width: 80%; height: 80%;
    background: radial-gradient(circle at 40% 35%, #1a2520, #0a0f0d);
    border-radius: 50%;
    position: relative;
    display: flex; align-items: center; justify-content: center;
    box-shadow: inset 0 0 40px rgba(0,0,0,0.8), 0 0 60px rgba(112,193,163,0.04);
  }
  .mock-ring {
    position: absolute; inset: 10%;
    border-radius: 50%;
    border: 1px solid rgba(112,193,163,0.4);
  }
  .mock-ring-2 { inset: 25%; border-color: rgba(112,193,163,0.25); }
  .mock-crosshair {
    position: absolute; inset: 0;
    display: flex; align-items: center; justify-content: center;
  }
  .ch-h {
    position: absolute; width: 60%; height: 1px;
    background: linear-gradient(90deg, transparent, rgba(112,193,163,0.2), transparent);
  }
  .ch-v {
    position: absolute; width: 1px; height: 60%;
    background: linear-gradient(180deg, transparent, rgba(112,193,163,0.2), transparent);
  }
  .mock-anomaly-spot {
    position: absolute; top: 28%; right: 22%;
    width: 22%; aspect-ratio: 1; border-radius: 50%;
    background: radial-gradient(circle, rgba(229,115,115,0.5), transparent 70%);
    animation: flicker .6s ease-in-out infinite alternate;
  }
  @keyframes flicker {
    from { opacity: .6; transform: scale(.95); }
    to   { opacity: 1;  transform: scale(1.05); }
  }
  .mock-scanline {
    position: absolute; left: 0; right: 0; height: 2px;
    background: linear-gradient(90deg, transparent, rgba(112,193,163,0.15), transparent);
    animation: scan 3s linear infinite;
    pointer-events: none;
  }
  @keyframes scan {
    from { top: 0; }
    to   { top: 100%; }
  }
  /* Corner brackets */
  .bracket {
    position: absolute; width: 18px; height: 18px;
    border-color: rgba(112,193,163,0.35); border-style: solid;
  }
  .tl { top: 16px; left: 16px; border-width: 1px 0 0 1px; }
  .tr { top: 16px; right: 16px; border-width: 1px 1px 0 0; }
  .bl { bottom: 16px; left: 16px; border-width: 0 0 1px 1px; }
  .br { bottom: 16px; right: 16px; border-width: 0 1px 1px 0; }

  .sam3-inferring {
    font-size: 9px; font-weight: 600; letter-spacing: .6px; text-transform: uppercase;
    color: #a78bfa; background: rgba(167,139,250,0.1); border: 1px solid rgba(167,139,250,0.25);
    border-radius: 4px; padding: 1px 6px;
    animation: pulse 1.2s ease-in-out infinite;
  }
  .sam3-error {
    font-size: 11px; color: #e57373; padding: 6px 0;
  }

  .mock-heatmap {
    position: absolute; inset: 0;
    background: radial-gradient(ellipse 25% 20% at 65% 30%, rgba(229,115,115,0.25), transparent 70%);
    pointer-events: none; transition: opacity .4s;
    mix-blend-mode: screen;
  }
</style>
