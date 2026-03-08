<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import CameraIcon from '@lucide/svelte/icons/camera';
  import type { PipelineNodeStatus } from '$lib/stores/pipeline.svelte';

  let { node }: { node: PipelineNodeStatus } = $props();

  let imgSrc = $state<string | null>(null);
  let refreshTimer = $state<ReturnType<typeof setInterval> | null>(null);

  function refreshFrame() {
    if (!node.has_frame) return;
    // Cache-busting with timestamp
    imgSrc = `/api/pipeline/frame/${node.id}?t=${Date.now()}`;
  }

  onMount(() => {
    refreshFrame();
    refreshTimer = setInterval(refreshFrame, 200);
  });

  onDestroy(() => {
    if (refreshTimer) clearInterval(refreshTimer);
  });

  const formattedFrameCount = $derived(node.frame_count.toLocaleString());

  const formattedTime = $derived(() => {
    if (!node.last_frame_time) return '--';
    const date = new Date(node.last_frame_time * 1000);
    return date.toLocaleTimeString('en-US', { hour12: false });
  });
</script>

<div class="rounded-lg border border-border bg-zinc-900 overflow-hidden flex flex-col">
  <div class="flex items-center gap-2 px-4 py-2.5 border-b border-border bg-zinc-900/80">
    <CameraIcon class="size-4 text-blue-400" />
    <span class="text-sm font-medium text-foreground truncate">{node.label}</span>
    <div class="ml-auto flex items-center gap-1.5">
      <span class="size-2 rounded-full {node.has_frame ? 'bg-green-500 animate-pulse' : 'bg-zinc-600'}"></span>
      <span class="text-xs text-muted-foreground">{node.status}</span>
    </div>
  </div>

  <div class="relative bg-black aspect-video flex items-center justify-center">
    {#if imgSrc && node.has_frame}
      <img
        src={imgSrc}
        alt="Live camera feed"
        class="w-full h-full object-contain"
      />
    {:else}
      <div class="text-muted-foreground text-sm">Waiting for camera...</div>
    {/if}
  </div>

  <div class="px-4 py-2 flex items-center gap-4 text-xs text-muted-foreground border-t border-border">
    <div>Frames: <span class="text-foreground font-mono">{formattedFrameCount}</span></div>
    <div class="ml-auto font-mono text-foreground">{formattedTime()}</div>
  </div>
</div>
