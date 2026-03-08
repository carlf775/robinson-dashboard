<script lang="ts">
  import { Handle, type NodeProps, Position } from '@xyflow/svelte';
  import BrainIcon from '@lucide/svelte/icons/brain';
  import PlayIcon from '@lucide/svelte/icons/play';
  import SquareIcon from '@lucide/svelte/icons/square';
  import PencilIcon from '@lucide/svelte/icons/pencil-line';
  import ZapIcon from '@lucide/svelte/icons/zap';
  import LoaderIcon from '@lucide/svelte/icons/loader';
  import CheckCircleIcon from '@lucide/svelte/icons/circle-check';
  import ImageIcon from '@lucide/svelte/icons/image';
  import RefreshCwIcon from '@lucide/svelte/icons/refresh-cw';
  import FolderPlusIcon from '@lucide/svelte/icons/folder-plus';
  import UploadIcon from '@lucide/svelte/icons/upload';
  import Button from '$lib/components/ui/button/button.svelte';
  import type { Sam3NodeData, Sam3State } from '$lib/types/flow';

  let { id, data }: NodeProps = $props();
  const nodeData = $derived(data as Sam3NodeData);

  const inputs = [
    { id: 'image', label: 'image' },
  ];

  const outputs = [
    { id: 'score', label: 'score' },
    { id: 'heatmap', label: 'heatmap' },
    { id: 'image', label: 'image' },
  ];

  const stateConfig: Record<Sam3State, { color: string; label: string }> = {
    needs_data: { color: 'bg-zinc-500', label: 'Needs Data' },
    collecting: { color: 'bg-blue-500', label: 'Collecting' },
    annotating: { color: 'bg-amber-500', label: 'Annotating' },
    ready_to_train: { color: 'bg-purple-500', label: 'Ready to Train' },
    training: { color: 'bg-orange-500', label: 'Training' },
    ready: { color: 'bg-green-500', label: 'Ready' },
  };

  const currentState = $derived(stateConfig[nodeData.state] ?? stateConfig.needs_data);
  const annotationCount = $derived(new Set((nodeData.annotations ?? []).map(a => a.imageHash)).size);
  const labelCount = $derived(nodeData.labels?.length ?? 0);
  const imageCount = $derived(nodeData.imageCount ?? 0);
</script>

<div class="rounded-lg shadow-lg min-w-[200px] bg-zinc-900 light:bg-white border border-zinc-700 light:border-zinc-200">
  <!-- Title bar -->
  <div class="flex items-center gap-2 rounded-t-lg bg-violet-600 px-3 py-1.5">
    <BrainIcon class="size-4 text-white" strokeWidth={1.5} />
    <span class="text-sm font-semibold text-white">{nodeData.label}</span>
  </div>

  <!-- Inputs & Outputs -->
  <div class="flex justify-between py-1.5">
    <!-- Inputs -->
    <div class="flex flex-col">
      {#each inputs as input}
        <div class="relative flex items-center px-3 py-1">
          <Handle
            type="target"
            position={Position.Left}
            id={input.id}
            class="!bg-violet-400 !w-2.5 !h-2.5 !border-2 !border-zinc-900 light:!border-white !left-[-5px]"
          />
          <span class="text-xs text-zinc-400 light:text-zinc-500 light:text-zinc-400 ml-1">{input.label}</span>
        </div>
      {/each}
    </div>
    <!-- Outputs -->
    <div class="flex flex-col">
      {#each outputs as output}
        <div class="relative flex items-center justify-end px-3 py-1">
          <span class="text-xs text-zinc-400 light:text-zinc-500 light:text-zinc-400 mr-1">{output.label}</span>
          <Handle
            type="source"
            position={Position.Right}
            id={output.id}
            class="!bg-violet-400 !w-2.5 !h-2.5 !border-2 !border-zinc-900 light:!border-white !right-[-5px]"
          />
        </div>
      {/each}
    </div>
  </div>

  <!-- State & Controls -->
  <div class="border-t border-zinc-700 light:border-zinc-200 px-3 py-2 flex flex-col gap-2">
    <!-- State badge -->
    <div class="flex items-center gap-2">
      {#if nodeData.state === 'collecting'}
        <span class="relative flex size-2.5">
          <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-blue-400 opacity-75"></span>
          <span class="relative inline-flex size-2.5 rounded-full bg-blue-500"></span>
        </span>
      {:else}
        <span class="size-2.5 rounded-full {currentState.color}"></span>
      {/if}
      <span class="text-xs text-zinc-400 light:text-zinc-500 light:text-zinc-400">{currentState.label}</span>
      {#if imageCount > 0}
        <span class="ml-auto px-1.5 py-0.5 text-[10px] rounded-full bg-blue-500/20 text-blue-400">{imageCount} imgs</span>
      {/if}
      {#if nodeData.state === 'annotating' || nodeData.state === 'ready_to_train'}
        <span class="ml-auto px-1.5 py-0.5 text-[10px] rounded-full bg-amber-500/20 text-amber-400">{annotationCount} labeled</span>
      {/if}
    </div>

    <!-- State-dependent buttons -->
    <div class="flex flex-col gap-1.5">
      {#if nodeData.state === 'needs_data'}
        {#if nodeData.collectionError}
          <div class="px-2 py-1 rounded bg-red-900/30 border border-red-800 text-[10px] text-red-400 text-center">
            {nodeData.collectionError}
          </div>
        {/if}
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onStateChange?.(id, 'collecting')}
          disabled={nodeData.isStartingPipeline}
        >
          {#if nodeData.isStartingPipeline}
            <LoaderIcon class="size-3 animate-spin" />
            Starting...
          {:else}
            <PlayIcon class="size-3" />
            Start Collecting
          {/if}
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onOpenAnnotator?.(id)}
        >
          <UploadIcon class="size-3" />
          Upload / Annotate
        </Button>
      {:else if nodeData.state === 'collecting'}
        <span class="text-[10px] text-blue-400/70 text-center">Run pipeline to capture frames</span>
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onStateChange?.(id, 'annotating')}
        >
          <SquareIcon class="size-3" />
          Stop &amp; Annotate
        </Button>
      {:else if nodeData.state === 'annotating'}
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onOpenAnnotator?.(id)}
        >
          <PencilIcon class="size-3" />
          Open Annotator
        </Button>
      {:else if nodeData.state === 'ready_to_train'}
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-purple-900/50 border-purple-700 text-purple-300 hover:bg-purple-800/50 hover:text-purple-100"
          onclick={() => nodeData.onTrain?.(id)}
        >
          <ZapIcon class="size-3" />
          Train Model
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onOpenAnnotator?.(id)}
        >
          <ImageIcon class="size-3" />
          Edit Annotations
        </Button>
      {:else if nodeData.state === 'training'}
        <div class="flex items-center justify-center gap-2 py-1">
          <LoaderIcon class="size-3 text-orange-400 animate-spin" />
          <span class="text-xs text-orange-400">Training...</span>
        </div>
      {:else if nodeData.state === 'ready'}
        <div class="flex items-center gap-2 py-1">
          <CheckCircleIcon class="size-3.5 text-green-400" />
          <span class="text-xs text-green-400">Model ready</span>
          {#if nodeData.modelId}
            <span class="text-[10px] text-zinc-500 light:text-zinc-400 ml-auto truncate max-w-[80px]" title={nodeData.modelId}>{nodeData.modelId}</span>
          {/if}
        </div>
        <div class="flex items-center gap-2">
          <span class="text-[10px] text-zinc-500 light:text-zinc-400 whitespace-nowrap">Threshold</span>
          <input
            type="range"
            min="0"
            max="1"
            step="0.05"
            value={nodeData.inferenceThreshold ?? 0.5}
            oninput={(e) => nodeData.onDataChange?.(id, { inferenceThreshold: parseFloat(e.currentTarget.value) })}
            class="flex-1 h-1 accent-green-500"
          />
          <span class="text-[10px] text-zinc-400 light:text-zinc-500 light:text-zinc-400 font-mono w-7 text-right">{((nodeData.inferenceThreshold ?? 0.5) * 100).toFixed(0)}%</span>
        </div>
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onTrain?.(id)}
        >
          <RefreshCwIcon class="size-3" />
          Retrain
        </Button>
        <Button
          variant="outline"
          size="sm"
          class="h-7 w-full text-xs bg-zinc-800 light:bg-zinc-100 border-zinc-700 light:border-zinc-200 text-zinc-300 light:text-zinc-700 hover:bg-zinc-700 light:hover:bg-zinc-200 hover:text-zinc-100 light:hover:text-zinc-900"
          onclick={() => nodeData.onStateChange?.(id, 'collecting')}
        >
          <FolderPlusIcon class="size-3" />
          Collect More
        </Button>
      {/if}
    </div>
  </div>
</div>
