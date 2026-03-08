<script lang="ts">
  import XIcon from '@lucide/svelte/icons/x';
  import PlayIcon from '@lucide/svelte/icons/play';
  import SquareIcon from '@lucide/svelte/icons/square';
  import BrainIcon from '@lucide/svelte/icons/brain';
  import LoaderIcon from '@lucide/svelte/icons/loader';
  import CheckCircleIcon from '@lucide/svelte/icons/circle-check';
  import EyeIcon from '@lucide/svelte/icons/eye';
  import EyeOffIcon from '@lucide/svelte/icons/eye-off';
  import Button from '$lib/components/ui/button/button.svelte';
  import type { Sam3Annotation, Sam3Detection, Sam3Prediction } from '$lib/types/flow';

  // Per-label color palette
  const LABEL_COLORS: string[] = [
    '#a78bfa', // violet
    '#f472b6', // pink
    '#38bdf8', // sky
    '#fb923c', // orange
    '#4ade80', // green
    '#facc15', // yellow
    '#e879f9', // fuchsia
    '#2dd4bf', // teal
  ];

  function labelColor(label: string, labels: string[]): string {
    const idx = labels.indexOf(label);
    return LABEL_COLORS[idx >= 0 ? idx % LABEL_COLORS.length : 0];
  }

  function labelColorRgba(label: string, labels: string[], alpha: number): string {
    const hex = labelColor(label, labels);
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  let {
    nodeId,
    label = 'SAM3',
    annotations = [],
    trainingConfig,
    existingPredictions,
    onclose,
    onsave,
    ongpuconflict,
  }: {
    nodeId: string;
    label: string;
    annotations: Sam3Annotation[];
    trainingConfig: { epochs: number; imageSize: number; patience: number };
    existingPredictions?: Sam3Prediction[];
    onclose: () => void;
    onsave: (modelId: string, imageSize: number, predictions: Sam3Prediction[]) => void;
    ongpuconflict?: (holder: string) => Promise<void>;
  } = $props();

  let epochs = $state(trainingConfig.epochs);
  let imageSize = $state(trainingConfig.imageSize);
  let patience = $state(trainingConfig.patience ?? 0);
  let status = $state<'idle' | 'compiling' | 'training' | 'inferring' | 'done' | 'error'>('idle');
  let currentEpoch = $state(0);
  let currentLoss = $state(0);
  let lossHistory = $state<number[]>([]);
  let lossComponents = $state<{
    loss_class?: number;
    loss_bbox?: number;
    loss_giou?: number;
    loss_mask_bce?: number;
    loss_mask_dice?: number;
  }>({});
  let error = $state<string | null>(null);
  let ws = $state<WebSocket | null>(null);
  let canvas = $state<HTMLCanvasElement | null>(null);

  // Prediction viewer state
  let predictions = $state<{ imageHash: string; detectionCount: number }[]>([]);
  let selectedPredHash = $state<string | null>(null);
  let selectedPrediction = $state<Sam3Prediction | null>(null);
  let showGt = $state(true);
  let showPredictions = $state(true);
  let completedModelId = $state<string | null>(null);
  let stoppedEarly = $state(false);
  let stoppedAtEpoch = $state(0);
  let minConfidence = $state(0.3);
  let bestThreshold = $state<number | null>(null);
  let bestF1 = $state(0);
  let allPredictionDetails = $state<Map<string, Sam3Prediction>>(new Map());

  // Per-label state
  let labelThresholds = $state<Record<string, number>>({});
  let labelVisibility = $state<Record<string, boolean>>({});
  let bestLabelThresholds = $state<Record<string, { threshold: number; f1: number }>>({});

  const goodCount = $derived(annotations.filter(a => a.label === 'good').length);
  const anomalyCount = $derived(annotations.filter(a => a.label === 'anomaly').length);
  const progress = $derived(epochs > 0 ? Math.round((currentEpoch / epochs) * 100) : 0);

  // Derive unique labels from all predictions
  const uniqueLabels = $derived.by(() => {
    const labelSet = new Set<string>();
    for (const pred of allPredictionDetails.values()) {
      for (const det of pred.detections) {
        labelSet.add(det.label);
      }
    }
    return [...labelSet].sort();
  });

  // Get GT annotation for the selected image
  const selectedGt = $derived(
    selectedPredHash ? annotations.find(a => a.imageHash === selectedPredHash) : null
  );

  // Filter detection using per-label thresholds and visibility
  function isDetectionVisible(d: Sam3Detection): boolean {
    const lbl = d.label;
    if (labelVisibility[lbl] === false) return false;
    return d.score >= (labelThresholds[lbl] ?? minConfidence);
  }

  // Detections filtered by per-label confidence thresholds
  const filteredDetections = $derived(
    selectedPrediction?.detections.filter(isDetectionVisible) ?? []
  );

  // Filtered detection count per image (for thumbnails)
  const filteredCountMap = $derived(
    new Map(
      predictions.map(p => {
        const pred = allPredictionDetails.get(p.imageHash);
        const count = pred?.detections.filter(isDetectionVisible).length ?? 0;
        return [p.imageHash, count] as [string, number];
      })
    )
  );

  function drawLossChart() {
    if (!canvas || lossHistory.length < 2) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const w = canvas.width;
    const h = canvas.height;
    const padding = 40;

    ctx.clearRect(0, 0, w, h);

    // Background
    ctx.fillStyle = '#18181b';
    ctx.fillRect(0, 0, w, h);

    // Grid lines
    ctx.strokeStyle = '#27272a';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = padding + ((h - 2 * padding) * i) / 4;
      ctx.beginPath();
      ctx.moveTo(padding, y);
      ctx.lineTo(w - padding, y);
      ctx.stroke();
    }

    const maxLoss = Math.max(...lossHistory) * 1.1 || 1;
    const minLoss = 0;

    // Axis labels
    ctx.fillStyle = '#71717a';
    ctx.font = '10px monospace';
    ctx.textAlign = 'right';
    for (let i = 0; i <= 4; i++) {
      const val = maxLoss - ((maxLoss - minLoss) * i) / 4;
      const y = padding + ((h - 2 * padding) * i) / 4;
      ctx.fillText(val.toFixed(3), padding - 5, y + 3);
    }

    // Epoch labels
    ctx.textAlign = 'center';
    const step = Math.max(1, Math.floor(lossHistory.length / 5));
    for (let i = 0; i < lossHistory.length; i += step) {
      const x = padding + ((w - 2 * padding) * i) / (lossHistory.length - 1);
      ctx.fillText(String(i + 1), x, h - padding + 15);
    }

    // Loss curve
    ctx.strokeStyle = '#a78bfa';
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < lossHistory.length; i++) {
      const x = padding + ((w - 2 * padding) * i) / (lossHistory.length - 1);
      const y = padding + ((h - 2 * padding) * (maxLoss - lossHistory[i])) / (maxLoss - minLoss);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
  }

  function initPerLabelState() {
    const newThresholds: Record<string, number> = {};
    const newVisibility: Record<string, boolean> = {};
    for (const lbl of uniqueLabels) {
      newThresholds[lbl] = labelThresholds[lbl] ?? minConfidence;
      newVisibility[lbl] = labelVisibility[lbl] ?? true;
    }
    labelThresholds = newThresholds;
    labelVisibility = newVisibility;
  }

  function computeOptimalThreshold() {
    if (allPredictionDetails.size === 0 || annotations.length === 0) return;

    // Collect all unique scores as candidate thresholds
    const scoreSet = new Set<number>([0]);
    for (const pred of allPredictionDetails.values()) {
      for (const det of pred.detections) {
        scoreSet.add(det.score);
      }
    }
    if (scoreSet.size <= 1) return; // no detections at all

    const candidates = [...scoreSet].sort((a, b) => a - b);

    // Global optimal threshold (image-level anomaly detection)
    let best = 0;
    let bestThr = 0.5;

    for (const threshold of candidates) {
      let tp = 0, fp = 0, fn = 0;

      for (const ann of annotations) {
        const isAnomaly = ann.label === 'anomaly';
        const pred = allPredictionDetails.get(ann.imageHash);
        const hasDetection = pred?.detections.some(d => d.score >= threshold) ?? false;

        if (isAnomaly && hasDetection) tp++;
        else if (isAnomaly && !hasDetection) fn++;
        else if (!isAnomaly && hasDetection) fp++;
      }

      const precision = tp + fp > 0 ? tp / (tp + fp) : 0;
      const recall = tp + fn > 0 ? tp / (tp + fn) : 0;
      const f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0;

      if (f1 >= best) {
        best = f1;
        bestThr = threshold;
      }
    }

    bestThreshold = bestThr;
    bestF1 = best;
    minConfidence = bestThr;

    // Per-label optimal thresholds
    const perLabel: Record<string, { threshold: number; f1: number }> = {};
    for (const lbl of uniqueLabels) {
      // Collect scores for this label
      const lblScores = new Set<number>([0]);
      for (const pred of allPredictionDetails.values()) {
        for (const det of pred.detections) {
          if ((det.label) === lbl) lblScores.add(det.score);
        }
      }
      const lblCandidates = [...lblScores].sort((a, b) => a - b);
      let lblBest = 0;
      let lblBestThr = 0.5;

      for (const threshold of lblCandidates) {
        let tp = 0, fp = 0, fn = 0;
        for (const ann of annotations) {
          const isAnomaly = ann.label === 'anomaly';
          const pred = allPredictionDetails.get(ann.imageHash);
          const hasLblDet = pred?.detections.some(d => d.label === lbl && d.score >= threshold) ?? false;

          if (isAnomaly && hasLblDet) tp++;
          else if (isAnomaly && !hasLblDet) fn++;
          else if (!isAnomaly && hasLblDet) fp++;
        }
        const precision = tp + fp > 0 ? tp / (tp + fp) : 0;
        const recall = tp + fn > 0 ? tp / (tp + fn) : 0;
        const f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0;
        if (f1 >= lblBest) {
          lblBest = f1;
          lblBestThr = threshold;
        }
      }
      perLabel[lbl] = { threshold: lblBestThr, f1: lblBest };
    }
    bestLabelThresholds = perLabel;

    // Initialize per-label thresholds to their optimal values
    const newThresholds: Record<string, number> = {};
    const newVisibility: Record<string, boolean> = {};
    for (const lbl of uniqueLabels) {
      newThresholds[lbl] = perLabel[lbl]?.threshold ?? bestThr;
      newVisibility[lbl] = true;
    }
    labelThresholds = newThresholds;
    labelVisibility = newVisibility;
  }

  function selectPrediction(hash: string) {
    selectedPredHash = hash;
    selectedPrediction = allPredictionDetails.get(hash) ?? null;
  }

  async function startTraining() {
    status = 'compiling';
    currentEpoch = 0;
    currentLoss = 0;
    lossHistory = [];
    error = null;
    completedModelId = null;
    stoppedEarly = false;
    stoppedAtEpoch = 0;
    minConfidence = 0.3;
    bestThreshold = null;
    bestF1 = 0;
    allPredictionDetails = new Map();
    predictions = [];
    selectedPredHash = null;
    selectedPrediction = null;
    labelThresholds = {};
    labelVisibility = {};
    bestLabelThresholds = {};

    // Connect to WebSocket for training progress
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}/ws`;
    const socket = new WebSocket(wsUrl);
    ws = socket;

    socket.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        console.log('[TrainingModal WS]', msg.type, msg.nodeId === nodeId ? '(match)' : `(want ${nodeId}, got ${msg.nodeId})`, msg.type === 'prediction' ? `detections=${msg.detections?.length}` : '');
        if (msg.type === 'training_status' && msg.phase === 'compiling') {
          status = 'compiling';
        }
        if (msg.type === 'training' && msg.nodeId === nodeId) {
          status = 'training';
          currentEpoch = msg.epoch;
          currentLoss = msg.loss;
          lossHistory = [...lossHistory, msg.loss];
          lossComponents = {
            loss_class: msg.loss_class,
            loss_bbox: msg.loss_bbox,
            loss_giou: msg.loss_giou,
            loss_mask_bce: msg.loss_mask_bce,
            loss_mask_dice: msg.loss_mask_dice,
          };
          drawLossChart();
        }
        if (msg.type === 'training_status' && msg.phase === 'inferring') {
          status = 'inferring';
        }
        if (msg.type === 'prediction' && msg.nodeId === nodeId) {
          const pred: Sam3Prediction = { imageHash: msg.imageHash, detections: msg.detections };
          allPredictionDetails.set(pred.imageHash, pred);
          allPredictionDetails = new Map(allPredictionDetails);
          predictions = [...predictions, { imageHash: pred.imageHash, detectionCount: pred.detections.length }];
          if (!selectedPredHash) selectPrediction(pred.imageHash);
        }
        if (msg.type === 'training_complete' && msg.nodeId === nodeId) {
          console.log('[TrainingModal] training_complete, predictions collected:', allPredictionDetails.size, 'predictions list:', predictions.length);
          status = 'done';
          completedModelId = msg.modelId ?? null;
          stoppedEarly = msg.stoppedEarly ?? false;
          stoppedAtEpoch = msg.stoppedAtEpoch ?? currentEpoch;
          computeOptimalThreshold();
          // Auto-save predictions to the graph
          const modelId = completedModelId || `sam3-${nodeId}-${Date.now()}`;
          const allPreds = [...allPredictionDetails.values()];
          console.log('[TrainingModal] saving', allPreds.length, 'predictions');
          onsave(modelId, imageSize, allPreds);
        }
        if (msg.type === 'training_error' && msg.nodeId === nodeId) {
          status = 'error';
          error = msg.error || 'Training failed';
        }
      } catch {
        // ignore non-JSON messages
      }
    };

    socket.onerror = () => {
      // WebSocket may not be available; fall back to POST polling
    };

    // Start training via API
    try {
      const res = await fetch('/api/train', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          node_id: nodeId,
          epochs,
          image_size: imageSize,
          patience,
          annotations: annotations.map(a => ({
            imageHash: a.imageHash,
            label: a.label,
            masks: (a.masks ?? []).map(m => ({ mask: m.mask, label: m.label })),
          })),
        }),
      });

      if (res.status === 409 && ongpuconflict) {
        const data = await res.json().catch(() => ({}));
        if (data.holder) {
          status = 'idle';
          await ongpuconflict(data.holder);
          // Retry after user resolved the conflict
          await startTraining();
          return;
        }
      }
      if (!res.ok) {
        const data = await res.json().catch(() => ({ error: 'Training request failed' }));
        error = data.error || `HTTP ${res.status}`;
        status = 'error';
        return;
      }
    } catch (e) {
      error = e instanceof Error ? e.message : 'Failed to start training';
      status = 'error';
    }
  }

  function stopTraining() {
    fetch('/api/train/stop', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ node_id: nodeId }),
    }).catch(() => {});

    status = 'idle';
    ws?.close();
    ws = null;
  }

  $effect(() => {
    return () => {
      ws?.close();
    };
  });

  $effect(() => {
    if (canvas && lossHistory.length > 0) {
      drawLossChart();
    }
  });

  // Initialize from existing predictions (loaded from node data)
  $effect(() => {
    if (existingPredictions && existingPredictions.length > 0 && allPredictionDetails.size === 0 && status === 'idle') {
      const details = new Map<string, Sam3Prediction>();
      const predList: { imageHash: string; detectionCount: number }[] = [];
      for (const pred of existingPredictions) {
        details.set(pred.imageHash, pred);
        predList.push({ imageHash: pred.imageHash, detectionCount: pred.detections.length });
      }
      allPredictionDetails = details;
      predictions = predList;
      status = 'done';
      computeOptimalThreshold();
      if (predList.length > 0) selectPrediction(predList[0].imageHash);
    }
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
  onkeydown={(e) => e.key === 'Escape' && onclose()}
>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="w-[calc(100vw-4rem)] h-[calc(100vh-4rem)] max-w-5xl bg-zinc-900 border border-border rounded-xl shadow-2xl flex flex-col overflow-hidden"
    onclick={(e) => e.stopPropagation()}
  >
    <!-- Header -->
    <div class="h-12 shrink-0 flex items-center justify-between px-4 border-b border-border">
      <div class="flex items-center gap-2">
        <BrainIcon class="size-4 text-violet-400" />
        <span class="text-sm font-semibold text-foreground">Training SAM3 — {label}</span>
      </div>
      <button class="text-muted-foreground hover:text-foreground transition-colors" onclick={onclose}>
        <XIcon class="size-4" />
      </button>
    </div>

    <!-- Content -->
    <div class="flex-1 flex overflow-hidden">
      <!-- Left: Config -->
      <div class="w-64 shrink-0 flex flex-col border-r border-border p-4 gap-4">
        <div>
          <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Dataset</span>
          <div class="mt-2 flex flex-col gap-1 text-xs text-zinc-300">
            <div class="flex justify-between">
              <span>Total images:</span>
              <span>{annotations.length}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-green-400">Good:</span>
              <span>{goodCount}</span>
            </div>
            <div class="flex justify-between">
              <span class="text-red-400">Anomaly:</span>
              <span>{anomalyCount}</span>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-3">
          <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Config</span>

          <div class="flex flex-col gap-1">
            <label for="epochs" class="text-xs text-zinc-400">Epochs</label>
            <input
              id="epochs"
              type="number"
              min="1"
              max="10000"
              class="h-8 rounded-md bg-zinc-800 border border-zinc-700 px-2 text-sm text-zinc-200 focus:outline-none focus:border-primary disabled:opacity-50"
              bind:value={epochs}
              disabled={status !== 'idle' && status !== 'error'}
            />
          </div>

          <div class="flex flex-col gap-1">
            <label for="imageSize" class="text-xs text-zinc-400">Image Size</label>
            <select
              id="imageSize"
              class="h-8 rounded-md bg-zinc-800 border border-zinc-700 px-2 text-sm text-zinc-200 focus:outline-none focus:border-primary disabled:opacity-50"
              bind:value={imageSize}
              disabled={status !== 'idle' && status !== 'error'}
            >
              <option value={336}>336 (fast)</option>
              <option value={504}>504 (default)</option>
              <option value={672}>672 (high res)</option>
            </select>
          </div>

          <div class="flex flex-col gap-1">
            <label for="patience" class="text-xs text-zinc-400">Early Stopping Patience</label>
            <input
              id="patience"
              type="number"
              min="0"
              max="1000"
              class="h-8 rounded-md bg-zinc-800 border border-zinc-700 px-2 text-sm text-zinc-200 focus:outline-none focus:border-primary disabled:opacity-50"
              bind:value={patience}
              disabled={status !== 'idle' && status !== 'error'}
            />
            <span class="text-[10px] text-zinc-500">0 = disabled</span>
          </div>
        </div>

        {#if status === 'training' || status === 'inferring'}
          <div class="flex flex-col gap-2 mt-auto">
            <div class="flex justify-between text-xs text-zinc-400">
              <span>Epoch {currentEpoch}/{epochs}</span>
              <span>{progress}%</span>
            </div>
            <div class="h-1.5 rounded-full bg-zinc-800 overflow-hidden">
              <div
                class="h-full rounded-full bg-violet-500 transition-all duration-300"
                style="width:{status === 'inferring' ? 100 : progress}%"
              ></div>
            </div>
            {#if status === 'inferring'}
              <div class="text-xs text-violet-400 flex items-center gap-1.5">
                <LoaderIcon class="size-3 animate-spin" />
                Running inference...
              </div>
            {:else}
              <div class="text-xs text-zinc-500">Loss: {currentLoss.toFixed(4)}</div>
              {#if lossComponents.loss_class != null}
                <div class="text-[10px] text-zinc-600 flex flex-col gap-0.5 mt-1">
                  <span>cls: {lossComponents.loss_class?.toFixed(4)} &middot; bbox: {lossComponents.loss_bbox?.toFixed(4)}</span>
                  <span>giou: {lossComponents.loss_giou?.toFixed(4)} &middot; bce: {lossComponents.loss_mask_bce?.toFixed(4)}</span>
                  <span>dice: {lossComponents.loss_mask_dice?.toFixed(4)}</span>
                </div>
              {/if}
            {/if}
          </div>
        {/if}

        {#if status === 'done' && predictions.length > 0}
          <div class="flex flex-col gap-2 mt-auto overflow-y-auto">
            <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Overlays</span>
            <button
              class="flex items-center gap-2 text-xs px-2 py-1 rounded transition-colors {showPredictions ? 'text-violet-300 bg-violet-500/10' : 'text-zinc-500 bg-zinc-800'}"
              onclick={() => showPredictions = !showPredictions}
            >
              {#if showPredictions}<EyeIcon class="size-3" />{:else}<EyeOffIcon class="size-3" />{/if}
              All Predictions
            </button>
            <button
              class="flex items-center gap-2 text-xs px-2 py-1 rounded transition-colors {showGt ? 'text-green-300 bg-green-500/10' : 'text-zinc-500 bg-zinc-800'}"
              onclick={() => showGt = !showGt}
            >
              {#if showGt}<EyeIcon class="size-3" />{:else}<EyeOffIcon class="size-3" />{/if}
              Ground Truth
              <span class="ml-auto size-2 rounded-full bg-green-500"></span>
            </button>

            <!-- Per-label controls -->
            {#if uniqueLabels.length > 0}
              <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider mt-2">Labels</span>
              {#each uniqueLabels as lbl}
                {@const color = labelColor(lbl, uniqueLabels)}
                {@const visible = labelVisibility[lbl] !== false}
                <div class="flex flex-col gap-1">
                  <button
                    class="flex items-center gap-2 text-xs px-2 py-1 rounded transition-colors"
                    style="color: {visible ? color : '#71717a'}; background: {visible ? color + '15' : '#27272a'}"
                    onclick={() => labelVisibility[lbl] = !visible}
                  >
                    {#if visible}<EyeIcon class="size-3" />{:else}<EyeOffIcon class="size-3" />{/if}
                    {lbl}
                    <span class="ml-auto size-2 rounded-full" style="background: {color}"></span>
                  </button>
                  {#if visible}
                    <div class="flex items-center gap-1.5 px-1">
                      <input
                        type="range"
                        min="0"
                        max="1"
                        step="0.01"
                        value={labelThresholds[lbl] ?? minConfidence}
                        oninput={(e) => labelThresholds[lbl] = parseFloat((e.target as HTMLInputElement).value)}
                        class="flex-1 h-1 rounded-full appearance-none bg-zinc-700 cursor-pointer"
                        style="accent-color: {color}"
                      />
                      <span class="text-[10px] font-mono text-zinc-400 w-7 text-right">{(labelThresholds[lbl] ?? minConfidence).toFixed(2)}</span>
                    </div>
                    {#if bestLabelThresholds[lbl]}
                      <button
                        class="text-[10px] px-1 transition-colors text-left"
                        style="color: {color}"
                        onclick={() => labelThresholds[lbl] = bestLabelThresholds[lbl].threshold}
                      >
                        F1: {bestLabelThresholds[lbl].threshold.toFixed(2)} ({bestLabelThresholds[lbl].f1.toFixed(2)})
                      </button>
                    {/if}
                  {/if}
                </div>
              {/each}
            {/if}

            <!-- Global fallback slider -->
            <div class="flex flex-col gap-1.5 mt-2 pt-2 border-t border-zinc-800">
              <div class="flex justify-between items-center">
                <span class="text-xs text-zinc-400">Min Floor</span>
                <span class="text-[10px] font-mono text-zinc-300">{minConfidence.toFixed(2)}</span>
              </div>
              <input
                type="range"
                min="0"
                max="1"
                step="0.01"
                bind:value={minConfidence}
                class="w-full h-1 rounded-full appearance-none bg-zinc-700 accent-violet-500 cursor-pointer"
              />
              {#if bestThreshold != null}
                <button
                  class="text-[10px] text-violet-400 hover:text-violet-300 transition-colors text-left"
                  onclick={() => {
                    minConfidence = bestThreshold!;
                    // Also set all per-label thresholds to their optimal values
                    for (const lbl of uniqueLabels) {
                      labelThresholds[lbl] = bestLabelThresholds[lbl]?.threshold ?? bestThreshold!;
                    }
                  }}
                >
                  Optimal F1: {bestThreshold.toFixed(2)} ({bestF1.toFixed(2)})
                </button>
              {/if}
            </div>
          </div>
        {/if}
      </div>

      <!-- Center: Loss chart + Prediction viewer -->
      <div class="flex-1 flex flex-col">
        <div class="flex-1 flex items-center justify-center p-6 overflow-hidden">
          {#if status === 'idle'}
            <div class="flex flex-col items-center gap-3 text-muted-foreground">
              <BrainIcon class="size-12 opacity-20" />
              <span class="text-sm">Configure and start training</span>
            </div>
          {:else if status === 'compiling'}
            <div class="flex flex-col items-center gap-3">
              <LoaderIcon class="size-8 text-violet-400 animate-spin" />
              <span class="text-sm font-semibold text-zinc-200">Compiling training step</span>
              <span class="text-xs text-zinc-500">This may take a few minutes</span>
            </div>
          {:else if status === 'error'}
            <div class="flex flex-col items-center gap-3">
              <span class="text-sm text-red-400">{error}</span>
            </div>
          {:else if status === 'done' && predictions.length > 0 && selectedPredHash}
            <!-- Prediction main view -->
            <div class="w-full h-full flex flex-col gap-3">
              <div class="flex items-center gap-3">
                <canvas
                  bind:this={canvas}
                  width={300}
                  height={160}
                  class="rounded-lg shrink-0"
                ></canvas>
                <div class="flex items-center gap-2 text-green-400">
                  <CheckCircleIcon class="size-4" />
                  <span class="text-xs font-medium">Training complete &middot; {predictions.length} predictions</span>
                </div>
              </div>
              <!-- Selected image with overlays -->
              <div class="flex-1 flex items-center justify-center relative overflow-hidden rounded-lg bg-zinc-950">
                  <div class="relative max-w-full max-h-full">
                    <img
                      src="/api/images/{selectedPredHash}"
                      alt="prediction"
                      class="block max-w-full max-h-[50vh] object-contain rounded"
                    />
                    <!-- Prediction overlays (per-label colors) -->
                    {#if showPredictions && selectedPrediction}
                      {#each filteredDetections as det}
                        {@const detColor = labelColor(det.label, uniqueLabels)}
                        <!-- Bounding box -->
                        <div
                          class="absolute border-2 rounded-sm pointer-events-none"
                          style="
                            border-color: {detColor};
                            left: {det.box[0] * 100}%;
                            top: {det.box[1] * 100}%;
                            width: {(det.box[2] - det.box[0]) * 100}%;
                            height: {(det.box[3] - det.box[1]) * 100}%;
                          "
                        >
                          <span
                            class="absolute -top-5 left-0 text-[10px] font-mono text-white px-1 rounded-sm whitespace-nowrap"
                            style="background: {detColor}cc"
                          >
                            {det.label} {det.score.toFixed(2)}
                          </span>
                        </div>
                        <!-- Mask overlay -->
                        {#if det.mask}
                          <div
                            class="absolute inset-0 w-full h-full pointer-events-none"
                            style="
                              background: {labelColorRgba(det.label, uniqueLabels, 0.3)};
                              -webkit-mask-image: url('data:image/png;base64,{det.mask}');
                              mask-image: url('data:image/png;base64,{det.mask}');
                              -webkit-mask-size: 100% 100%;
                              mask-size: 100% 100%;
                              -webkit-mask-repeat: no-repeat;
                              mask-repeat: no-repeat;
                              -webkit-mask-mode: luminance;
                              mask-mode: luminance;
                            "
                          ></div>
                        {/if}
                      {/each}
                    {/if}
                    <!-- Ground truth overlays (green) -->
                    {#if showGt && selectedGt?.masks}
                      {#each selectedGt.masks as gtMask}
                        <div
                          class="absolute inset-0 w-full h-full pointer-events-none"
                          style="
                            background: rgba(74, 222, 128, 0.25);
                            -webkit-mask-image: url('data:image/png;base64,{gtMask.mask}');
                            mask-image: url('data:image/png;base64,{gtMask.mask}');
                            -webkit-mask-size: 100% 100%;
                            mask-size: 100% 100%;
                            -webkit-mask-repeat: no-repeat;
                            mask-repeat: no-repeat;
                            -webkit-mask-mode: luminance;
                            mask-mode: luminance;
                          "
                        ></div>
                      {/each}
                    {/if}
                  </div>
              </div>
            </div>
          {:else if status === 'done'}
            <div class="flex flex-col items-center gap-4">
              <canvas
                bind:this={canvas}
                width={600}
                height={350}
                class="rounded-lg"
              ></canvas>
              <div class="flex items-center gap-2 text-green-400">
                <CheckCircleIcon class="size-5" />
                <span class="text-sm font-medium">Training complete!</span>
              </div>
            </div>
          {:else}
            <canvas
              bind:this={canvas}
              width={600}
              height={350}
              class="rounded-lg"
            ></canvas>
          {/if}
        </div>

        <!-- Bottom: Thumbnail strip -->
        {#if status === 'training' || status === 'inferring'}
          <div class="h-32 shrink-0 border-t border-border p-3">
            <span class="text-[10px] text-zinc-500 uppercase tracking-wider">
              {status === 'inferring' ? 'Running inference on training images...' : 'Preview (available after training)'}
            </span>
            <div class="flex gap-2 mt-2 overflow-x-auto">
              {#each { length: 5 } as _, i}
                <div class="size-20 shrink-0 rounded bg-zinc-800 flex items-center justify-center">
                  {#if status === 'inferring'}
                    <LoaderIcon class="size-4 animate-spin text-zinc-600" />
                  {:else}
                    <span class="text-[10px] text-zinc-600">#{i + 1}</span>
                  {/if}
                </div>
              {/each}
            </div>
          </div>
        {:else if status === 'done' && predictions.length > 0}
          <div class="h-28 shrink-0 border-t border-border p-3">
            <span class="text-[10px] text-zinc-500 uppercase tracking-wider">
              Predictions ({predictions.length} images)
            </span>
            <div class="flex gap-2 mt-2 overflow-x-auto pb-1">
              {#each predictions as pred}
                <button
                  class="size-18 shrink-0 rounded relative overflow-hidden border-2 transition-colors {selectedPredHash === pred.imageHash ? 'border-violet-500' : 'border-transparent hover:border-zinc-600'}"
                  onclick={() => selectPrediction(pred.imageHash)}
                >
                  <img
                    src="/api/images/{pred.imageHash}"
                    alt="thumbnail"
                    class="w-full h-full object-cover rounded-sm"
                  />
                  {#if (filteredCountMap.get(pred.imageHash) ?? pred.detectionCount) > 0}
                    <span class="absolute top-0.5 right-0.5 text-[9px] font-mono bg-violet-500/90 text-white px-1 rounded-full min-w-[16px] text-center">
                      {filteredCountMap.get(pred.imageHash) ?? pred.detectionCount}
                    </span>
                  {/if}
                </button>
              {/each}
            </div>
          </div>
        {/if}
      </div>
    </div>

    <!-- Bottom bar -->
    <div class="h-14 shrink-0 flex items-center justify-between px-4 border-t border-border">
      <div class="text-xs text-muted-foreground">
        {#if status === 'compiling'}
          <span class="text-violet-400">Compiling training step...</span>
        {:else if status === 'training'}
          <span class="text-violet-400">Training epoch {currentEpoch} of {epochs}...</span>
        {:else if status === 'inferring'}
          <span class="text-violet-400">Running post-training inference...</span>
        {:else if status === 'done'}
          <span class="text-green-400">
            {#if stoppedEarly}Stopped early at epoch {stoppedAtEpoch}{:else}Training finished{/if} — final loss: {currentLoss.toFixed(4)}
          </span>
        {:else if status === 'error'}
          <span class="text-red-400">{error}</span>
        {/if}
      </div>
      <div class="flex items-center gap-2">
        {#if status === 'idle' || status === 'error'}
          <Button
            variant="outline"
            size="sm"
            class="bg-zinc-800 border-zinc-700 text-zinc-300 hover:bg-zinc-700"
            onclick={onclose}
          >
            Close
          </Button>
          <Button
            size="sm"
            onclick={startTraining}
            disabled={annotations.length === 0}
          >
            <PlayIcon class="size-3" />
            Start Training
          </Button>
        {:else if status === 'compiling' || status === 'training' || status === 'inferring'}
          <Button
            variant="outline"
            size="sm"
            class="bg-zinc-800 border-zinc-700 text-zinc-300 hover:bg-zinc-700"
            onclick={stopTraining}
          >
            <SquareIcon class="size-3" />
            Stop
          </Button>
        {:else if status === 'done'}
          <Button
            variant="outline"
            size="sm"
            class="bg-zinc-800 border-zinc-700 text-zinc-300 hover:bg-zinc-700"
            onclick={onclose}
          >
            Close
          </Button>
        {/if}
      </div>
    </div>
  </div>
</div>
