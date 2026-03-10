<script lang="ts">
  import { onMount } from 'svelte';
  import DatabaseIcon from '@lucide/svelte/icons/database';
  import ShieldCheckIcon from '@lucide/svelte/icons/shield-check';
  import ShieldAlertIcon from '@lucide/svelte/icons/shield-alert';
  import XIcon from '@lucide/svelte/icons/x';
  import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
  import ChevronRightIcon from '@lucide/svelte/icons/chevron-right';

  type Sample = {
    key: string;
    anomalous: boolean;
    score: number;
  };

  let samples = $state<Sample[]>([]);
  let loading = $state(true);
  let error = $state('');

  let filter = $state<'all' | 'anomaly' | 'good'>('all');

  let lightboxIdx = $state<number | null>(null);

  onMount(async () => {
    try {
      const r = await fetch(import.meta.env.BASE_URL + 'robinson_samples.json');
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      samples = await r.json();
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  });

  const filtered = $derived(
    filter === 'all' ? samples :
    filter === 'anomaly' ? samples.filter(s => s.anomalous) :
    samples.filter(s => !s.anomalous)
  );

  function openLightbox(idx: number) { lightboxIdx = idx; }
  function closeLightbox() { lightboxIdx = null; }
  function prev() { if (lightboxIdx !== null) lightboxIdx = (lightboxIdx - 1 + filtered.length) % filtered.length; }
  function next() { if (lightboxIdx !== null) lightboxIdx = (lightboxIdx + 1) % filtered.length; }

  function onKeydown(e: KeyboardEvent) {
    if (lightboxIdx === null) return;
    if (e.key === 'Escape') closeLightbox();
    if (e.key === 'ArrowLeft') prev();
    if (e.key === 'ArrowRight') next();
  }

  const totalCount = $derived(samples.length);
  const anomalyCount = $derived(samples.filter(s => s.anomalous).length);
  const goodCount = $derived(samples.filter(s => !s.anomalous).length);
</script>

<svelte:window onkeydown={onKeydown} />

<div class="flex flex-col gap-4 p-4 h-full overflow-auto">
  <!-- Header -->
  <div class="flex items-center gap-2">
    <DatabaseIcon class="size-4 text-primary" />
    <h2 class="text-sm font-semibold text-foreground">Robinson Dataset Sample</h2>
    <span class="text-xs text-muted-foreground ml-1">— {totalCount} images</span>
  </div>

  <!-- Filter + stats bar -->
  <div class="flex items-center gap-3 flex-wrap">
    <div class="flex items-center gap-1 rounded-md border border-zinc-700 bg-zinc-900 p-1">
      {#each (['all', 'anomaly', 'good'] as const) as f}
        <button
          class="px-3 py-1 rounded text-xs font-medium transition-colors
            {filter === f ? 'bg-zinc-700 text-foreground' : 'text-muted-foreground hover:text-foreground'}"
          onclick={() => filter = f}
        >
          {f === 'all' ? `All (${totalCount})` : f === 'anomaly' ? `Anomaly (${anomalyCount})` : `Good (${goodCount})`}
        </button>
      {/each}
    </div>

    <div class="flex items-center gap-4 ml-auto text-xs text-muted-foreground">
      <span class="flex items-center gap-1.5">
        <ShieldAlertIcon class="size-3 text-destructive" />
        {anomalyCount} anomalies
        <span class="text-zinc-500">({totalCount > 0 ? ((anomalyCount/totalCount)*100).toFixed(0) : 0}%)</span>
      </span>
      <span class="flex items-center gap-1.5">
        <ShieldCheckIcon class="size-3 text-primary" />
        {goodCount} good
      </span>
    </div>
  </div>

  <!-- Gallery grid -->
  {#if loading}
    <div class="flex-1 flex items-center justify-center text-muted-foreground text-sm">Loading…</div>
  {:else if error}
    <div class="flex-1 flex items-center justify-center text-destructive text-sm">{error}</div>
  {:else if filtered.length === 0}
    <div class="flex-1 flex items-center justify-center text-muted-foreground text-sm">No images</div>
  {:else}
    <div class="grid grid-cols-4 gap-2 sm:grid-cols-5 md:grid-cols-6 lg:grid-cols-8">
      {#each filtered as sample, i}
        <button
          class="relative aspect-square rounded-md overflow-hidden border border-zinc-700 hover:border-primary transition-colors group"
          onclick={() => openLightbox(i)}
          title="{sample.key} — score: {sample.score.toFixed(3)}"
        >
          <img
            src="{import.meta.env.BASE_URL}images/{sample.key}.jpg"
            alt={sample.key}
            class="w-full h-full object-cover"
            loading="lazy"
          />
          <!-- Badge -->
          <div class="absolute top-1 right-1">
            {#if sample.anomalous}
              <span class="size-2 rounded-full bg-destructive block"></span>
            {:else}
              <span class="size-2 rounded-full bg-primary block"></span>
            {/if}
          </div>
          <!-- Hover overlay -->
          <div class="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-end p-1">
            <span class="text-[9px] text-white font-mono truncate w-full">{sample.key}</span>
          </div>
        </button>
      {/each}
    </div>
  {/if}
</div>

<!-- Lightbox -->
{#if lightboxIdx !== null}
  {@const sample = filtered[lightboxIdx]}
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div
    class="fixed inset-0 z-50 bg-black/90 flex items-center justify-center"
    onclick={closeLightbox}
  >
    <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
    <div class="relative max-w-2xl w-full mx-4" onclick={(e) => e.stopPropagation()}>
      <img
        src="{import.meta.env.BASE_URL}images/{sample.key}.jpg"
        alt={sample.key}
        class="w-full rounded-md"
      />
      <!-- Info bar -->
      <div class="mt-2 flex items-center gap-3 text-sm">
        <span class="font-mono text-zinc-300">{sample.key}</span>
        {#if sample.anomalous}
          <span class="flex items-center gap-1 text-destructive text-xs"><ShieldAlertIcon class="size-3" /> ANOMALY</span>
        {:else}
          <span class="flex items-center gap-1 text-primary text-xs"><ShieldCheckIcon class="size-3" /> GOOD</span>
        {/if}
        <span class="ml-auto text-xs text-zinc-500">score: {sample.score.toFixed(4)}</span>
        <span class="text-xs text-zinc-500">{lightboxIdx + 1} / {filtered.length}</span>
      </div>

      <!-- Nav buttons -->
      <button
        class="absolute left-2 top-1/2 -translate-y-1/2 size-8 flex items-center justify-center rounded-full bg-black/60 hover:bg-black text-white"
        onclick={prev}
      ><ChevronLeftIcon class="size-4" /></button>
      <button
        class="absolute right-2 top-1/2 -translate-y-1/2 size-8 flex items-center justify-center rounded-full bg-black/60 hover:bg-black text-white"
        onclick={next}
      ><ChevronRightIcon class="size-4" /></button>

      <!-- Close -->
      <button
        class="absolute -top-10 right-0 size-8 flex items-center justify-center rounded-full bg-black/60 hover:bg-black text-white"
        onclick={closeLightbox}
      ><XIcon class="size-4" /></button>
    </div>
  </div>
{/if}
