<script lang="ts">
  import PencilRulerIcon from '@lucide/svelte/icons/pencil-ruler';
  import PlayIcon from '@lucide/svelte/icons/play';
  import BarChart3Icon from '@lucide/svelte/icons/bar-chart-3';
  import DatabaseIcon from '@lucide/svelte/icons/database';
  import SunIcon from '@lucide/svelte/icons/sun';
  import MoonIcon from '@lucide/svelte/icons/moon';
  import { themeStore } from '$lib/stores/theme.svelte';

  let {
    activeTab = $bindable('editor' as 'editor' | 'run' | 'analytics' | 'dataset'),
  }: {
    activeTab: 'editor' | 'run' | 'analytics' | 'dataset';
  } = $props();
</script>

<nav class="w-12 shrink-0 flex flex-col items-center border-r border-border bg-zinc-900">
  <div class="h-12 shrink-0 flex items-center justify-center border-b border-border w-full">
    <img src="{import.meta.env.BASE_URL + 'trademark.png'}" alt="Deepvis" class="w-6 object-contain" onerror={() => {}} />
  </div>
  <div class="flex flex-col items-center gap-1 pt-3">
    <button
      class="size-9 flex items-center justify-center rounded-md transition-colors
        {activeTab === 'editor'
          ? 'bg-primary/20 text-primary'
          : 'text-muted-foreground hover:text-foreground hover:bg-sidebar-border'}"
      onclick={() => (activeTab = 'editor')}
      title="Editor"
    >
      <PencilRulerIcon class="size-4" />
    </button>
    <button
      class="size-9 flex items-center justify-center rounded-md transition-colors
        {activeTab === 'run'
          ? 'bg-primary/20 text-primary'
          : 'text-muted-foreground hover:text-foreground hover:bg-sidebar-border'}"
      onclick={() => (activeTab = 'run')}
      title="Run"
    >
      <PlayIcon class="size-4" />
    </button>
    <button
      class="size-9 flex items-center justify-center rounded-md transition-colors
        {activeTab === 'analytics'
          ? 'bg-primary/20 text-primary'
          : 'text-muted-foreground hover:text-foreground hover:bg-sidebar-border'}"
      onclick={() => (activeTab = 'analytics')}
      title="Analytics"
    >
      <BarChart3Icon class="size-4" />
    </button>
    <button
      class="size-9 flex items-center justify-center rounded-md transition-colors
        {activeTab === 'dataset'
          ? 'bg-primary/20 text-primary'
          : 'text-muted-foreground hover:text-foreground hover:bg-sidebar-border'}"
      onclick={() => (activeTab = 'dataset')}
      title="Real Dataset"
    >
      <DatabaseIcon class="size-4" />
    </button>
  </div>

  <div class="mt-auto pb-3 flex flex-col items-center">
    <button
      class="size-9 flex items-center justify-center rounded-md transition-colors text-muted-foreground hover:text-foreground hover:bg-sidebar-border"
      onclick={() => themeStore.toggle()}
      title="Toggle theme"
    >
      {#if themeStore.theme === 'dark'}
        <SunIcon class="size-4" />
      {:else}
        <MoonIcon class="size-4" />
      {/if}
    </button>
  </div>
</nav>
