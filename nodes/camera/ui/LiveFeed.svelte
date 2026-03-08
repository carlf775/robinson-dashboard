<script lang="ts">
  interface Props {
    cameraId: string;
    active?: boolean;
  }

  let { cameraId, active = false }: Props = $props();
  let imgEl: HTMLImageElement | undefined = $state();
  let containerEl: HTMLDivElement | undefined = $state();
  let status = $state<'idle' | 'connecting' | 'streaming' | 'error'>('idle');
  let polling = false;
  let streamStarted = false;

  // Pan & zoom state
  let scale = $state(1);
  let translateX = $state(0);
  let translateY = $state(0);
  let dragging = false;
  let dragStartX = 0;
  let dragStartY = 0;
  let dragOriginX = 0;
  let dragOriginY = 0;

  function handleWheel(e: WheelEvent) {
    e.preventDefault();
    const rect = containerEl?.getBoundingClientRect();
    if (!rect) return;

    // Mouse position relative to container center
    const cx = e.clientX - rect.left - rect.width / 2;
    const cy = e.clientY - rect.top - rect.height / 2;

    const oldScale = scale;
    const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    const newScale = Math.min(Math.max(scale * factor, 1), 20);

    // Zoom toward cursor
    translateX = cx - (cx - translateX) * (newScale / oldScale);
    translateY = cy - (cy - translateY) * (newScale / oldScale);
    scale = newScale;

    if (newScale === 1) {
      translateX = 0;
      translateY = 0;
    }
  }

  function handlePointerDown(e: PointerEvent) {
    if (scale <= 1) return;
    dragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    dragOriginX = translateX;
    dragOriginY = translateY;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function handlePointerMove(e: PointerEvent) {
    if (!dragging) return;
    translateX = dragOriginX + (e.clientX - dragStartX);
    translateY = dragOriginY + (e.clientY - dragStartY);
  }

  function handlePointerUp() {
    dragging = false;
  }

  function handleDblClick() {
    scale = 1;
    translateX = 0;
    translateY = 0;
  }

  const transform = $derived(
    `scale(${scale}) translate(${translateX / scale}px, ${translateY / scale}px)`
  );

  async function startPolling() {
    if (!cameraId || polling) return;
    polling = true;
    status = 'connecting';

    try {
      // Start the camera stream on the backend
      const startRes = await fetch(`/api/stream/start?id=${encodeURIComponent(cameraId)}`, {
        method: 'POST',
      });
      if (!startRes.ok) throw new Error(`Start stream failed: ${startRes.status}`);
      streamStarted = true;

      // Poll for JPEG snapshots — fetch next frame immediately after displaying current
      while (polling) {
        try {
          const res = await fetch('/api/stream/snapshot', { cache: 'no-store' });
          if (res.ok && res.headers.get('Content-Type')?.includes('image/jpeg')) {
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            if (imgEl) {
              const oldSrc = imgEl.src;
              imgEl.src = url;
              if (oldSrc && oldSrc.startsWith('blob:')) {
                URL.revokeObjectURL(oldSrc);
              }
            }
            if (status !== 'streaming') status = 'streaming';
          } else {
            // No frame ready yet, brief pause before retry
            await new Promise((r) => setTimeout(r, 16));
          }
        } catch {
          await new Promise((r) => setTimeout(r, 100));
        }
      }
    } catch (e) {
      console.error('Stream failed:', e);
      status = 'error';
    }
  }

  async function stopPolling() {
    polling = false;

    if (streamStarted) {
      await fetch('/api/stream/stop', { method: 'POST' }).catch(() => {});
      streamStarted = false;
    }

    // Revoke last object URL
    if (imgEl?.src?.startsWith('blob:')) {
      URL.revokeObjectURL(imgEl.src);
    }
    status = 'idle';
  }

  $effect(() => {
    if (active && cameraId) {
      startPolling();
      return () => {
        stopPolling();
      };
    }
  });
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  bind:this={containerEl}
  class="w-full aspect-video bg-zinc-800 rounded-lg overflow-hidden border border-zinc-700 relative"
  style="cursor: {scale > 1 ? (dragging ? 'grabbing' : 'grab') : 'default'}"
  onwheel={handleWheel}
  onpointerdown={handlePointerDown}
  onpointermove={handlePointerMove}
  onpointerup={handlePointerUp}
  onpointercancel={handlePointerUp}
  ondblclick={handleDblClick}
>
  {#if status !== 'streaming'}
    <div class="absolute inset-0 flex items-center justify-center">
      <span class="text-sm text-zinc-500">
        {#if status === 'connecting'}
          Connecting...
        {:else if status === 'error'}
          Stream error
        {:else}
          Live feed
        {/if}
      </span>
    </div>
  {/if}
  <img
    bind:this={imgEl}
    alt="Live camera feed"
    class="w-full h-full object-contain select-none"
    style="transform: {transform}; transform-origin: center center;"
    draggable="false"
  />
  {#if scale > 1}
    <div class="absolute bottom-2 right-2 bg-black/60 rounded px-1.5 py-0.5 text-[10px] text-zinc-400 pointer-events-none">
      {Math.round(scale * 100)}%
    </div>
  {/if}
</div>
