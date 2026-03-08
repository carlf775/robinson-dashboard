<script lang="ts">
  import XIcon from '@lucide/svelte/icons/x';
  import LoaderIcon from '@lucide/svelte/icons/loader';
  import SettingsIcon from '@lucide/svelte/icons/settings';
  import LockIcon from '@lucide/svelte/icons/lock';
  import CrosshairIcon from '@lucide/svelte/icons/crosshair';
  import ChevronDownIcon from '@lucide/svelte/icons/chevron-down';
  import ChevronRightIcon from '@lucide/svelte/icons/chevron-right';
  import UndoIcon from '@lucide/svelte/icons/undo-2';
  import Button from '$lib/components/ui/button/button.svelte';
  import LiveFeed from './LiveFeed.svelte';
  import { getProfile, type CameraProfile, type SettingDef } from '$lib/camera-profiles';

  interface SettingField {
    type: 'int' | 'float' | 'bool' | 'enum';
    value: number | string | boolean;
    min?: number;
    max?: number;
    options?: string[];
    readonly?: boolean;
  }

  let {
    cameraId,
    label = 'Camera',
    vendor,
    model,
    initialSettings = {},
    onsave,
    onclose,
  }: {
    cameraId: string;
    label?: string;
    vendor?: string;
    model?: string;
    initialSettings?: Record<string, number | string | boolean>;
    onsave: (settings: Record<string, number | string | boolean>) => void;
    onclose: () => void;
  } = $props();

  let fields = $state<Record<string, SettingField>>({});
  let originalFields = $state<Record<string, SettingField>>({});
  let loading = $state(true);
  let saving = $state(false);
  let cancelling = $state(false);
  let triggering = $state(false);
  let error = $state<string | null>(null);
  let collapsedSections = $state<Record<string, boolean>>({});

  // Per-channel values for channel-sliders widget: valueKey -> { channel: value }
  let channelValues = $state<Record<string, Record<string, number>>>({});
  let originalChannelValues = $state<Record<string, Record<string, number>>>({});

  const profile = $derived(getProfile(vendor, model));

  type Entry = {
    key: string;
    label: string;
    hint?: string;
    widget?: 'slider' | 'channel-sliders';
    selectorKey?: string;
    min?: number;
    max?: number;
    field: SettingField;
  };

  /** Build grouped sections from profile, filtering to keys present in fields */
  const profileSections = $derived.by(() => {
    if (!profile) return null;
    const available = new Set(Object.keys(fields));
    const used = new Set<string>();
    const sections: { label: string; entries: Entry[] }[] = [];

    for (const section of profile.sections) {
      const entries: Entry[] = [];
      for (const s of section.settings) {
        if (available.has(s.key)) {
          entries.push({
            key: s.key, label: s.label, hint: s.hint,
            widget: s.widget, selectorKey: s.selectorKey,
            min: s.min, max: s.max,
            field: fields[s.key],
          });
          used.add(s.key);
          // Also mark the selector key as consumed so it doesn't appear in "Other"
          if (s.selectorKey) used.add(s.selectorKey);
        }
      }
      if (entries.length > 0) {
        sections.push({ label: section.label, entries });
      }
    }

    const remaining: Entry[] = [];
    for (const key of Object.keys(fields)) {
      if (!used.has(key)) {
        remaining.push({ key, label: key, field: fields[key] });
      }
    }
    if (remaining.length > 0) {
      sections.push({ label: 'Other', entries: remaining });
    }

    return sections;
  });

  function toggleSection(label: string) {
    collapsedSections = { ...collapsedSections, [label]: !collapsedSections[label] };
  }

  async function handleTrigger() {
    triggering = true;
    try {
      const res = await fetch(`/api/camera-trigger?id=${encodeURIComponent(cameraId)}`, {
        method: 'POST',
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
    } catch (e) {
      error = e instanceof Error ? e.message : 'Trigger failed';
    } finally {
      triggering = false;
    }
  }

  function cloneFields(f: Record<string, SettingField>): Record<string, SettingField> {
    const out: Record<string, SettingField> = {};
    for (const [k, v] of Object.entries(f)) {
      out[k] = { ...v, options: v.options ? [...v.options] : undefined };
    }
    return out;
  }

  /** After loading fields, cycle through channel-slider selectors to read per-channel values */
  async function loadChannelValues() {
    if (!profile) return;
    const cv: Record<string, Record<string, number>> = {};

    for (const section of profile.sections) {
      for (const s of section.settings) {
        if (s.widget !== 'channel-sliders' || !s.selectorKey) continue;
        const selectorField = fields[s.selectorKey];
        if (!selectorField?.options) continue;

        const values: Record<string, number> = {};
        for (const channel of selectorField.options) {
          try {
            const res = await fetch(`/api/camera-settings?id=${encodeURIComponent(cameraId)}`, {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ [s.selectorKey]: channel }),
            });
            if (res.ok) {
              const updated: Record<string, SettingField> = await res.json();
              values[channel] = Number(updated[s.key]?.value ?? 0);
            }
          } catch {
            values[channel] = 0;
          }
        }
        cv[s.key] = values;
      }
    }

    channelValues = cv;
    originalChannelValues = JSON.parse(JSON.stringify(cv));
  }

  async function fetchSettings() {
    try {
      const res = await fetch(`/api/camera-settings?id=${encodeURIComponent(cameraId)}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      fields = await res.json();
    } catch {
      fields = {};
      for (const [k, v] of Object.entries(initialSettings)) {
        fields[k] = { type: typeof v === 'boolean' ? 'bool' : typeof v === 'number' ? 'int' : 'enum', value: v };
      }
    } finally {
      originalFields = cloneFields(fields);
      loading = false;
    }
    await loadChannelValues();
  }

  function flatValues(f?: Record<string, SettingField>): Record<string, number | string | boolean> {
    const src = f ?? fields;
    const out: Record<string, number | string | boolean> = {};
    for (const [k, field] of Object.entries(src)) {
      out[k] = field.value;
    }
    return out;
  }

  // Throttle: one in-flight request per key, queues latest value
  let pending = new Map<string, { body: Record<string, number | string | boolean>; resolve?: () => void }>();
  let inflight = new Set<string>();

  async function throttledPut(throttleKey: string, body: Record<string, number | string | boolean>) {
    pending.set(throttleKey, { body });
    if (inflight.has(throttleKey)) return; // will be picked up when current request finishes
    inflight.add(throttleKey);
    while (pending.has(throttleKey)) {
      const entry = pending.get(throttleKey)!;
      pending.delete(throttleKey);
      error = null;
      try {
        const res = await fetch(`/api/camera-settings?id=${encodeURIComponent(cameraId)}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(entry.body),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const updated: Record<string, SettingField> = await res.json();
        // Merge read-back for regular settings (not channel sliders)
        for (const [k, f] of Object.entries(updated)) {
          if (fields[k]) {
            fields[k] = { ...fields[k], value: f.value, min: f.min, max: f.max };
          }
        }
      } catch (e) {
        error = e instanceof Error ? e.message : `Failed to apply setting`;
      }
    }
    inflight.delete(throttleKey);
  }

  /** Apply a single setting to the camera immediately */
  function applySetting(key: string, value: number | string | boolean) {
    throttledPut(key, { [key]: value });
  }

  /** Apply a channel-slider value: set selector then brightness in one request */
  function applyChannelValue(valueKey: string, selectorKey: string, channel: string, value: number) {
    channelValues = {
      ...channelValues,
      [valueKey]: { ...channelValues[valueKey], [channel]: value },
    };
    throttledPut(`${valueKey}:${channel}`, { [selectorKey]: channel, [valueKey]: value });
  }

  /** Save = persist current settings to node data and close */
  async function handleSave() {
    saving = true;
    error = null;
    try {
      onsave(flatValues());
    } finally {
      saving = false;
    }
  }

  /** Cancel = revert to original settings on camera, then close */
  async function handleCancel() {
    cancelling = true;
    error = null;
    try {
      // Revert per-channel values
      if (profile) {
        for (const section of profile.sections) {
          for (const s of section.settings) {
            if (s.widget !== 'channel-sliders' || !s.selectorKey) continue;
            const orig = originalChannelValues[s.key];
            if (!orig) continue;
            for (const [channel, brightness] of Object.entries(orig)) {
              await fetch(`/api/camera-settings?id=${encodeURIComponent(cameraId)}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ [s.selectorKey]: channel, [s.key]: brightness }),
              });
            }
          }
        }
      }
      // Revert regular settings
      await fetch(`/api/camera-settings?id=${encodeURIComponent(cameraId)}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(flatValues(originalFields)),
      });
    } catch (e) {
      error = e instanceof Error ? e.message : 'Failed to revert settings';
    } finally {
      cancelling = false;
      onclose();
    }
  }

  function handleInput(key: string, value: string) {
    const field = fields[key];
    if (!field) return;
    let parsed: number | string | boolean;
    if (field.type === 'int') {
      const num = parseInt(value, 10);
      if (isNaN(num)) return;
      parsed = num;
    } else if (field.type === 'float') {
      const num = parseFloat(value);
      if (isNaN(num)) return;
      parsed = num;
    } else if (field.type === 'bool') {
      parsed = value === 'true';
    } else {
      parsed = value;
    }
    fields[key] = { ...field, value: parsed };
    applySetting(key, parsed);
  }

  $effect(() => {
    fetchSettings();
  });

  const fieldEntries = $derived(Object.entries(fields));
</script>

{#snippet settingInput(key: string, field: SettingField)}
  {#if field.type === 'enum' && field.options}
    <select
      id="setting-{key}"
      class="h-8 rounded-md bg-zinc-800 border border-zinc-700 px-2 text-sm text-zinc-200 focus:outline-none focus:border-primary disabled:opacity-50 disabled:cursor-not-allowed"
      disabled={field.readonly}
      value={String(field.value)}
      onchange={(e) => handleInput(key, e.currentTarget.value)}
    >
      {#each field.options as opt}
        <option value={opt}>{opt}</option>
      {/each}
    </select>
  {:else if field.type === 'bool'}
    <select
      id="setting-{key}"
      class="h-8 rounded-md bg-zinc-800 border border-zinc-700 px-2 text-sm text-zinc-200 focus:outline-none focus:border-primary disabled:opacity-50 disabled:cursor-not-allowed"
      disabled={field.readonly}
      value={String(field.value)}
      onchange={(e) => handleInput(key, e.currentTarget.value)}
    >
      <option value="true">true</option>
      <option value="false">false</option>
    </select>
  {:else}
    <input
      id="setting-{key}"
      type={field.type === 'int' || field.type === 'float' ? 'number' : 'text'}
      step={field.type === 'float' ? 'any' : '1'}
      class="h-8 rounded-md bg-zinc-800 border border-zinc-700 px-2 text-sm text-zinc-200 focus:outline-none focus:border-primary disabled:opacity-50 disabled:cursor-not-allowed"
      disabled={field.readonly}
      value={field.value}
      onchange={(e) => handleInput(key, e.currentTarget.value)}
    />
  {/if}
{/snippet}

{#snippet sliderInput(key: string, field: SettingField, fallbackMin: number, fallbackMax: number)}
  {@const rangeMin = field.min ?? fallbackMin}
  {@const rangeMax = field.max ?? fallbackMax}
  <div class="flex items-center gap-3">
    <input
      id="setting-{key}"
      type="range"
      min={rangeMin}
      max={rangeMax}
      step="1"
      class="flex-1 h-2 accent-primary cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
      disabled={field.readonly}
      value={Number(field.value)}
      oninput={(e) => handleInput(key, e.currentTarget.value)}
    />
    <span class="text-xs text-zinc-400 tabular-nums w-8 text-right">{field.value}</span>
  </div>
{/snippet}

{#snippet channelSlidersInput(valueKey: string, selectorKey: string, fallbackMin: number, fallbackMax: number)}
  {@const valueField = fields[valueKey]}
  {@const rangeMin = valueField?.min ?? fallbackMin}
  {@const rangeMax = valueField?.max ?? fallbackMax}
  {#if channelValues[valueKey]}
    <div class="flex flex-col gap-2">
      {#each Object.entries(channelValues[valueKey]) as [channel, brightness]}
        <div class="flex items-center gap-3">
          <span class="text-xs text-zinc-500 w-20 truncate" title={channel}>{channel}</span>
          <input
            type="range"
            min={rangeMin}
            max={rangeMax}
            step="1"
            class="flex-1 h-2 accent-primary cursor-pointer"
            value={brightness}
            oninput={(e) => applyChannelValue(valueKey, selectorKey, channel, parseInt(e.currentTarget.value, 10))}
          />
          <span class="text-xs text-zinc-400 tabular-nums w-8 text-right">{brightness}</span>
        </div>
      {/each}
    </div>
  {/if}
{/snippet}

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm"
  onkeydown={(e) => e.key === 'Escape' && handleCancel()}
  onclick={handleCancel}
>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="w-[calc(100vw-4rem)] max-h-[85vh] bg-zinc-900 border border-border rounded-xl shadow-2xl flex flex-col overflow-hidden"
    onclick={(e) => e.stopPropagation()}
  >
    <!-- Header -->
    <div class="h-12 shrink-0 flex items-center justify-between px-4 border-b border-border">
      <div class="flex items-center gap-2">
        <SettingsIcon class="size-4 text-primary" />
        <span class="text-sm font-semibold text-foreground">Camera Settings — {label}</span>
      </div>
      <button class="text-muted-foreground hover:text-foreground transition-colors" onclick={handleCancel}>
        <XIcon class="size-4" />
      </button>
    </div>

    <!-- Content: two-panel layout -->
    <div class="flex-1 flex overflow-hidden">
      <!-- Left panel: Live camera feed + trigger -->
      <div class="w-1/2 flex flex-col border-r border-border">
        <div class="flex-1 flex items-center justify-center p-6">
          <LiveFeed {cameraId} active={!loading} />
        </div>
        <div class="shrink-0 px-4 py-3 border-t border-border">
          <Button
            variant="outline"
            size="sm"
            class="w-full bg-zinc-800 border-zinc-700 text-zinc-200 hover:bg-zinc-700 hover:text-white"
            onclick={handleTrigger}
            disabled={triggering}
          >
            {#if triggering}
              <LoaderIcon class="size-3 animate-spin" />
            {:else}
              <CrosshairIcon class="size-3" />
            {/if}
            Software Trigger
          </Button>
        </div>
      </div>

      <!-- Right panel: Parameters -->
      <div class="w-1/2 flex flex-col">
        {#if loading}
          <div class="flex-1 flex flex-col items-center justify-center gap-3">
            <LoaderIcon class="size-6 text-muted-foreground animate-spin" />
            <span class="text-sm text-muted-foreground">Loading settings...</span>
          </div>
        {:else}
          <div class="flex-1 overflow-y-auto p-4 dark-scrollbar">
            {#if fieldEntries.length === 0}
              <div class="flex items-center justify-center h-full">
                <span class="text-sm text-muted-foreground">No parameters available</span>
              </div>
            {:else if profileSections}
              <!-- Grouped profile view -->
              <div class="flex flex-col gap-1">
                {#each profileSections as section}
                  <div class="rounded-lg border border-zinc-800 overflow-hidden">
                    <!-- Section header -->
                    <button
                      class="w-full flex items-center gap-2 px-3 py-2 bg-zinc-800/50 hover:bg-zinc-800 transition-colors text-left"
                      onclick={() => toggleSection(section.label)}
                    >
                      {#if collapsedSections[section.label]}
                        <ChevronRightIcon class="size-3.5 text-zinc-500" />
                      {:else}
                        <ChevronDownIcon class="size-3.5 text-zinc-500" />
                      {/if}
                      <span class="text-xs font-semibold text-zinc-300 uppercase tracking-wider">{section.label}</span>
                      <span class="text-[10px] text-zinc-600 ml-auto">{section.entries.length}</span>
                    </button>

                    <!-- Section content -->
                    {#if !collapsedSections[section.label]}
                      <div class="flex flex-col gap-3 p-3">
                        {#each section.entries as entry}
                          <div class="flex flex-col gap-1">
                            <label class="text-xs font-medium text-zinc-400 flex items-center gap-1.5" for="setting-{entry.key}">
                              {entry.label}
                              {#if entry.field.readonly}
                                <LockIcon class="size-3 text-zinc-600" />
                              {/if}
                              {#if entry.hint}
                                <span class="text-[10px] text-zinc-600" title={entry.hint}>?</span>
                              {/if}
                            </label>
                            <span class="text-[10px] text-zinc-600 -mt-0.5">{entry.key}</span>
                            {#if entry.widget === 'channel-sliders' && entry.selectorKey}
                              {@render channelSlidersInput(entry.key, entry.selectorKey, entry.min ?? 0, entry.max ?? 255)}
                            {:else if entry.widget === 'slider'}
                              {@render sliderInput(entry.key, entry.field, entry.min ?? 0, entry.max ?? 255)}
                            {:else}
                              {@render settingInput(entry.key, entry.field)}
                            {/if}
                          </div>
                        {/each}
                      </div>
                    {/if}
                  </div>
                {/each}
              </div>
            {:else}
              <!-- Flat fallback (no profile) -->
              <div class="flex flex-col gap-3">
                {#each fieldEntries as [key, field]}
                  <div class="flex flex-col gap-1">
                    <label class="text-xs font-medium text-zinc-400 flex items-center gap-1.5" for="setting-{key}">
                      {key}
                      {#if field.readonly}
                        <LockIcon class="size-3 text-zinc-600" />
                      {/if}
                    </label>
                    {@render settingInput(key, field)}
                  </div>
                {/each}
              </div>
            {/if}
          </div>

          <!-- Error message -->
          {#if error}
            <div class="px-4 py-2 text-xs text-red-400">{error}</div>
          {/if}

          <!-- Footer buttons -->
          <div class="shrink-0 flex items-center justify-end gap-2 px-4 py-3 border-t border-border">
            <Button
              variant="outline"
              size="sm"
              class="bg-zinc-800 border-zinc-700 text-zinc-300 hover:bg-zinc-700"
              onclick={handleCancel}
              disabled={cancelling}
            >
              {#if cancelling}
                <UndoIcon class="size-3 animate-spin" />
              {/if}
              Cancel
            </Button>
            <Button
              size="sm"
              onclick={handleSave}
              disabled={saving}
            >
              {#if saving}
                <LoaderIcon class="size-3 animate-spin" />
              {/if}
              Save
            </Button>
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>

<style>
  .dark-scrollbar {
    scrollbar-color: #3f3f46 transparent;
  }
  .dark-scrollbar::-webkit-scrollbar {
    width: 6px;
  }
  .dark-scrollbar::-webkit-scrollbar-track {
    background: transparent;
  }
  .dark-scrollbar::-webkit-scrollbar-thumb {
    background: #3f3f46;
    border-radius: 3px;
  }
  .dark-scrollbar::-webkit-scrollbar-thumb:hover {
    background: #52525b;
  }
</style>
