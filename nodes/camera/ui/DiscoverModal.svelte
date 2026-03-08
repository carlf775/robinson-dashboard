<script lang="ts">
  import XIcon from '@lucide/svelte/icons/x';
  import LoaderIcon from '@lucide/svelte/icons/loader';
  import CameraIcon from '@lucide/svelte/icons/camera';
  import CheckIcon from '@lucide/svelte/icons/check';
  import NetworkIcon from '@lucide/svelte/icons/network';
  import type { DiscoveredCamera } from '$lib/types/flow';

  let {
    currentCameraId = '',
    onselect,
    onclose,
  }: {
    currentCameraId?: string;
    onselect: (camera: DiscoveredCamera) => void;
    onclose: () => void;
  } = $props();

  let cameras = $state<DiscoveredCamera[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  async function fetchCameras() {
    error = null;
    try {
      const res = await fetch('/api/cameras/discover');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      cameras = await res.json();
    } catch (e) {
      error = e instanceof Error ? e.message : 'Discovery failed';
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    fetchCameras();
    const interval = setInterval(fetchCameras, 3000);
    return () => clearInterval(interval);
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
  onkeydown={(e) => e.key === 'Escape' && onclose()}
  onclick={onclose}
>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="w-[460px] max-h-[75vh] bg-zinc-900 border border-border rounded-xl shadow-2xl flex flex-col overflow-hidden"
    onclick={(e) => e.stopPropagation()}
  >
    <!-- Header -->
    <div class="h-12 shrink-0 flex items-center justify-between px-4 border-b border-border">
      <div class="flex items-center gap-2">
        <NetworkIcon class="size-4 text-primary" />
        <span class="text-sm font-semibold text-foreground">Discover Cameras</span>
      </div>
      <div class="flex items-center gap-3">
        {#if !loading && cameras.length > 0}
          <div class="flex items-center gap-1.5">
            <LoaderIcon class="size-3 text-muted-foreground animate-spin" />
            <span class="text-[11px] text-muted-foreground">{cameras.length} found</span>
          </div>
        {/if}
        <button class="text-muted-foreground hover:text-foreground transition-colors" onclick={onclose}>
          <XIcon class="size-4" />
        </button>
      </div>
    </div>

    <!-- Content -->
    <div class="flex-1 overflow-y-auto p-2">
      {#if loading}
        <div class="flex flex-col items-center justify-center py-16 gap-3">
          <LoaderIcon class="size-6 text-muted-foreground animate-spin" />
          <span class="text-sm text-muted-foreground">Scanning network...</span>
        </div>
      {:else if cameras.length === 0}
        <div class="flex flex-col items-center justify-center py-16 gap-3">
          <LoaderIcon class="size-5 text-muted-foreground animate-spin" />
          <span class="text-sm text-muted-foreground">
            {error ? 'Retrying...' : 'No cameras found — scanning...'}
          </span>
        </div>
      {:else}
        <div class="flex flex-col gap-1.5">
          {#each cameras as camera}
            {@const isSelected = camera.id === currentCameraId}
            <button
              class="w-full text-left rounded-lg px-3 py-3 transition-colors
                {isSelected
                  ? 'bg-primary/10 border border-primary/40 ring-1 ring-primary/20'
                  : 'border border-transparent hover:bg-zinc-800 hover:border-zinc-700'}"
              onclick={() => onselect(camera)}
            >
              <div class="flex items-start gap-3">
                <!-- Camera icon -->
                <div class="mt-0.5 shrink-0 size-8 rounded-md flex items-center justify-center
                  {isSelected ? 'bg-primary/20 text-primary' : 'bg-zinc-800 text-zinc-400'}">
                  <CameraIcon class="size-4" strokeWidth={1.5} />
                </div>

                <!-- Info -->
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-medium text-foreground">{camera.vendor} {camera.model}</span>
                    {#if isSelected}
                      <CheckIcon class="size-3.5 text-primary shrink-0" />
                    {/if}
                  </div>
                  <div class="flex items-center gap-3 mt-0.5">
                    <span class="text-xs text-muted-foreground font-mono">{camera.id}</span>
                    {#if camera.serial_number}
                      <span class="text-xs text-muted-foreground">SN: {camera.serial_number}</span>
                    {/if}
                  </div>
                  {#if camera.user_name}
                    <div class="mt-0.5">
                      <span class="text-xs text-zinc-500">{camera.user_name}</span>
                    </div>
                  {/if}
                </div>

                <!-- Status dot -->
                <div class="mt-2 shrink-0">
                  <span class="relative flex size-2">
                    <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-green-400 opacity-75"></span>
                    <span class="relative inline-flex size-2 rounded-full bg-green-500"></span>
                  </span>
                </div>
              </div>
            </button>
          {/each}
        </div>
      {/if}
    </div>
  </div>
</div>
