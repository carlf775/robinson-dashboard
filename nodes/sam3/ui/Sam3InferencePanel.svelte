<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import BrainIcon from '@lucide/svelte/icons/brain';
  import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
  import ShieldAlertIcon from '@lucide/svelte/icons/shield-alert';
  import type { PipelineNodeStatus } from '$lib/stores/pipeline.svelte';

  let { node }: { node: PipelineNodeStatus } = $props();

  let frameSrc = $state<string | null>(null);
  let heatmapSrc = $state<string | null>(null);
  let refreshTimer = $state<ReturnType<typeof setInterval> | null>(null);

  function refreshImages() {
    const ts = Date.now();
    if (node.has_frame) {
      frameSrc = `/api/pipeline/frame/${node.id}?t=${ts}`;
    }
    if (node.has_heatmap) {
      heatmapSrc = `/api/pipeline/heatmap/${node.id}?t=${ts}`;
    }
  }

  onMount(() => {
    refreshImages();
    refreshTimer = setInterval(refreshImages, 250);
  });

  onDestroy(() => {
    if (refreshTimer) clearInterval(refreshTimer);
  });

  const score = $derived(node.score ?? 0);
  const scorePercent = $derived(Math.round(score * 100));

  const scoreColor = $derived(() => {
    if (score < 0.3) return 'text-green-400';
    if (score < 0.5) return 'text-yellow-400';
    if (score < 0.8) return 'text-orange-400';
    return 'text-red-400';
  });

  const scoreBgColor = $derived(() => {
    if (score < 0.3) return 'bg-green-500/20';
    if (score < 0.5) return 'bg-yellow-500/20';
    if (score < 0.8) return 'bg-orange-500/20';
    return 'bg-red-500/20';
  });

  const isInferring = $derived(node.status === 'inferring');
</script>

<div class="rounded-lg border border-border bg-zinc-900 overflow-hidden flex flex-col">
  <div class="flex items-center gap-2 px-4 py-2.5 border-b border-border bg-zinc-900/80">
    <BrainIcon class="size-4 text-violet-400" />
    <span class="text-sm font-medium text-foreground truncate">{node.label}</span>
    <div class="ml-auto flex items-center gap-1.5">
      <span class="size-2 rounded-full {isInferring ? 'bg-violet-500 animate-pulse' : 'bg-zinc-600'}"></span>
      <span class="text-xs text-muted-foreground">{node.status}</span>
    </div>
  </div>

  <div class="flex gap-0">
    <!-- Frame + heatmap overlay -->
    <div class="relative bg-black aspect-video flex-1 flex items-center justify-center min-h-[200px]">
      {#if frameSrc && node.has_frame}
        <img
          src={frameSrc}
          alt="Inference frame"
          class="w-full h-full object-contain"
        />
        {#if heatmapSrc && node.has_heatmap}
          <img
            src={heatmapSrc}
            alt="Heatmap overlay"
            class="absolute inset-0 w-full h-full object-contain"
          />
        {/if}
      {:else if isInferring}
        <div class="text-muted-foreground text-sm">Starting inference...</div>
      {:else}
        <div class="text-muted-foreground text-sm">Waiting for inference...</div>
      {/if}
    </div>

    <!-- Score sidebar -->
    <div class="w-36 border-l border-border flex flex-col items-center justify-center gap-3 px-3 py-4">
      {#if node.score != null}
        <!-- Score display -->
        <div class="text-center">
          <div class="text-3xl font-bold font-mono {scoreColor()}">{scorePercent}%</div>
          <div class="text-[10px] text-muted-foreground mt-0.5">anomaly score</div>
        </div>

        <!-- Pass/Fail badge -->
        {#if node.is_anomalous}
          <div class="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-red-500/20 border border-red-500/40">
            <ShieldAlertIcon class="size-3.5 text-red-400" />
            <span class="text-xs font-semibold text-red-400">ANOMALY</span>
          </div>
        {:else}
          <div class="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-green-500/20 border border-green-500/40">
            <ShieldCheckIcon class="size-3.5 text-green-400" />
            <span class="text-xs font-semibold text-green-400">PASS</span>
          </div>
        {/if}

        <!-- Detection count -->
        {#if (node.detection_count ?? 0) > 0}
          <div class="text-center">
            <div class="text-lg font-mono text-foreground">{node.detection_count}</div>
            <div class="text-[10px] text-muted-foreground">detections</div>
          </div>
        {/if}
      {:else}
        <div class="text-xs text-muted-foreground text-center">No data yet</div>
      {/if}
    </div>
  </div>

  <div class="px-4 py-2 flex items-center gap-4 text-xs text-muted-foreground border-t border-border">
    <div>Frames: <span class="text-foreground font-mono">{node.frame_count.toLocaleString()}</span></div>
    {#if (node.image_count ?? 0) > 0}
      <div>Collected: <span class="text-blue-400 font-mono">{(node.image_count ?? 0).toLocaleString()}</span></div>
    {/if}
  </div>
</div>
