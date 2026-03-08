<script lang="ts">
  import { Handle, type NodeProps, Position } from '@xyflow/svelte';
  import CameraIcon from '@lucide/svelte/icons/camera';
  import SearchIcon from '@lucide/svelte/icons/search';
  import SettingsIcon from '@lucide/svelte/icons/settings';
  import Button from '$lib/components/ui/button/button.svelte';
  import type { CameraNodeData } from '$lib/types/flow';

  let { id, data }: NodeProps = $props();
  const nodeData = $derived(data as CameraNodeData);

  const outputs = [
    { id: 'image', label: 'image' },
    { id: 'timestamp', label: 'timestamp' },
  ];

  const hasCamera = $derived(!!nodeData.cameraId);
  const settingsCount = $derived(nodeData.settings ? Object.keys(nodeData.settings).length : 0);

  const statusColor = $derived(hasCamera ? 'bg-green-500' : 'bg-zinc-500');
  const statusLabel = $derived(hasCamera ? 'Ready' : 'No camera');

  const cameraInfo = $derived(
    nodeData.cameraId
      ? (nodeData.userName || (nodeData.vendor && nodeData.model ? `${nodeData.vendor} ${nodeData.model}` : nodeData.cameraId))
      : null
  );
</script>

<div class="rounded-lg shadow-lg min-w-[180px] bg-zinc-900 light:bg-white border border-zinc-700 light:border-zinc-200">
  <!-- Title bar -->
  <div class="flex items-center gap-2 rounded-t-lg bg-primary px-3 py-1.5">
    <CameraIcon class="size-4 text-primary-foreground" strokeWidth={1.5} />
    <span class="text-sm font-semibold text-primary-foreground">{nodeData.label}</span>
  </div>

  <!-- Outputs -->
  <div class="flex flex-col py-1.5">
    {#each outputs as output}
      <div class="relative flex items-center justify-end px-3 py-1">
        <span class="text-xs text-zinc-400 light:text-zinc-500">{output.label}</span>
        <Handle
          type="source"
          position={Position.Right}
          id={output.id}
          class="!bg-primary !w-2.5 !h-2.5 !border-2 !border-zinc-900 light:!border-white !right-[-5px]"
        />
      </div>
    {/each}
  </div>

  <!-- Settings section -->
  <div class="border-t border-zinc-700 light:border-zinc-200 px-3 py-2 flex flex-col gap-2">
    <!-- Status indicator -->
    <div class="flex items-center gap-2">
      <span class="size-2.5 rounded-full {statusColor}"></span>
      <span class="text-xs text-zinc-400 light:text-zinc-500">{statusLabel}</span>
    </div>

    <!-- Selected camera info -->
    {#if cameraInfo}
      <div class="text-xs text-zinc-300 light:text-zinc-700 truncate" title={nodeData.cameraId}>{cameraInfo}</div>
    {/if}

    <!-- Buttons -->
    <div class="flex flex-col gap-1.5">
      <Button
        variant="outline"
        size="sm"
        class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
        onclick={() => nodeData.onDiscover?.(id)}
      >
        <SearchIcon class="size-3" />
        Discover
      </Button>
      <Button
        variant="outline"
        size="sm"
        class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
        disabled={!hasCamera}
        onclick={() => nodeData.onSettings?.(id)}
      >
        <SettingsIcon class="size-3" />
        Settings
        {#if settingsCount > 0}
          <span class="ml-1 px-1.5 py-0.5 text-[10px] rounded-full bg-primary/20 text-primary">{settingsCount}</span>
        {/if}
      </Button>
    </div>
  </div>
</div>
