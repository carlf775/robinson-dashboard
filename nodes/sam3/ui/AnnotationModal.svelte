<script lang="ts">
  import XIcon from '@lucide/svelte/icons/x';
  import LoaderIcon from '@lucide/svelte/icons/loader';
  import TagIcon from '@lucide/svelte/icons/tag';
  import CheckIcon from '@lucide/svelte/icons/check';
  import AlertTriangleIcon from '@lucide/svelte/icons/triangle-alert';
  import Trash2Icon from '@lucide/svelte/icons/trash-2';
  import UploadIcon from '@lucide/svelte/icons/upload';
  import CirclePlusIcon from '@lucide/svelte/icons/circle-plus';
  import CircleMinusIcon from '@lucide/svelte/icons/circle-minus';
  import Undo2Icon from '@lucide/svelte/icons/undo-2';
  import EraserIcon from '@lucide/svelte/icons/eraser';
  import PlusIcon from '@lucide/svelte/icons/plus';
  import Button from '$lib/components/ui/button/button.svelte';
  import { untrack } from 'svelte';
  import type { Sam3Annotation, Sam3Point, Sam3Mask, AnnotationLabel } from '$lib/types/flow';

  interface ImageEntry {
    id: number;
    hash: string;
    width?: number;
    height?: number;
    captured_at?: string;
  }

  let {
    programId,
    nodeId,
    cameraId,
    annotations = [],
    labels = [],
    onsave,
    onclose,
    ongpuconflict,
  }: {
    programId?: number;
    nodeId: string;
    cameraId?: string;
    annotations: Sam3Annotation[];
    labels: AnnotationLabel[];
    onsave: (annotations: Sam3Annotation[], labels: AnnotationLabel[]) => void;
    onclose: () => void;
    ongpuconflict?: (holder: string) => Promise<void>;
  } = $props();

  let images = $state<ImageEntry[]>([]);
  let loading = $state(true);
  let selectedHash = $state<string | null>(null);
  let localAnnotations = $state<Sam3Annotation[]>([...annotations]);
  let localLabels = $state<AnnotationLabel[]>([...(labels ?? [])]);
  let filterLabel = $state<'all' | 'good' | 'anomaly' | 'unlabeled'>('all');
  let uploading = $state(false);

  // Label management state
  let activeLabelId = $state<string | null>(null);
  let addingLabel = $state(false);
  let newLabelName = $state('');
  let newLabelKind = $state<'anomaly' | 'good'>('anomaly');
  let editingLabelId = $state<string | null>(null);
  let editLabelName = $state('');
  let editLabelKind = $state<'anomaly' | 'good'>('anomaly');

  const LABEL_COLORS = ['#ef4444', '#f97316', '#eab308', '#22c55e', '#06b6d4', '#3b82f6', '#8b5cf6', '#ec4899'];

  // Distinct colors for mask overlays (label-based)
  const MASK_COLORS = [
    '#8b5cf6', // violet
    '#06b6d4', // cyan
    '#f97316', // orange
    '#22c55e', // green
    '#ec4899', // pink
    '#eab308', // yellow
    '#3b82f6', // blue
    '#ef4444', // red
  ];

  /** Return a stable color for a mask label. Unlabeled masks use their index. */
  function maskColor(label: string | undefined, index: number): string {
    if (!label) return MASK_COLORS[index % MASK_COLORS.length];
    // Simple stable hash from the label string
    let h = 0;
    for (let i = 0; i < label.length; i++) h = ((h << 5) - h + label.charCodeAt(i)) | 0;
    return MASK_COLORS[((h % MASK_COLORS.length) + MASK_COLORS.length) % MASK_COLORS.length];
  }

  // Auto-create default labels if none exist
  if (localLabels.length === 0) {
    if (localAnnotations.some(a => !a.labelId)) {
      // Migrate legacy annotations (no labelId)
      const kinds = new Set(localAnnotations.map(a => a.label));
      const newLabels: AnnotationLabel[] = [];
      if (kinds.has('good')) {
        newLabels.push({ id: crypto.randomUUID(), name: 'Good', kind: 'good', color: '#22c55e' });
      }
      if (kinds.has('anomaly')) {
        newLabels.push({ id: crypto.randomUUID(), name: 'Anomaly', kind: 'anomaly', color: '#ef4444' });
      }
      localLabels = newLabels;
      localAnnotations = localAnnotations.map(a => {
        if (a.labelId) return a;
        const lbl = newLabels.find(l => l.kind === a.label);
        return lbl ? { ...a, labelId: lbl.id } : a;
      });
    } else {
      // Fresh start — create default Good + Anomaly labels
      localLabels = [
        { id: crypto.randomUUID(), name: 'Good', kind: 'good', color: '#22c55e' },
        { id: crypto.randomUUID(), name: 'Anomaly', kind: 'anomaly', color: '#ef4444' },
      ];
    }
  }

  // Auto-select the first anomaly label so SAM3 tools are immediately visible
  if (!activeLabelId) {
    const firstAnomaly = localLabels.find(l => l.kind === 'anomaly');
    if (firstAnomaly) activeLabelId = firstAnomaly.id;
  }

  // SAM3 state
  type ToolMode = 'positive' | 'negative';
  let toolMode = $state<ToolMode>('positive');
  let maskLabel = $state('');
  let labelDropdownOpen = $state(false);
  let labelSearch = $state('');

  // Collect unique labels from all existing masks
  const existingMaskLabels = $derived(() => {
    const set = new Set<string>();
    for (const a of localAnnotations) {
      for (const m of a.masks ?? []) {
        if (m.label) set.add(m.label);
      }
    }
    return [...set].sort();
  });

  const filteredMaskLabels = $derived(() => {
    const all = existingMaskLabels();
    if (!labelSearch.trim()) return all;
    const q = labelSearch.trim().toLowerCase();
    return all.filter(l => l.toLowerCase().includes(q));
  });

  function selectMaskLabel(label: string) {
    maskLabel = label;
    labelSearch = '';
    labelDropdownOpen = false;
  }

  function handleLabelSearchKeydown(e: KeyboardEvent) {
    e.stopPropagation();
    if (e.key === 'Enter') {
      const q = labelSearch.trim();
      if (q) {
        // Select exact match or create new
        selectMaskLabel(q);
      }
      if (previewMask) acceptMask();
    }
    if (e.key === 'Escape') {
      labelDropdownOpen = false;
      labelSearch = '';
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
    }
  }
  let currentPoints = $state<Sam3Point[]>([]);
  interface DetectionBox {
    box: number[];
    score: number;
    selected: boolean;
  }
  let previewMask = $state<{ base64: string; iou: number; detections?: DetectionBox[] } | null>(null);
  let segmenting = $state(false);
  let encoding = $state(false);
  let encodedHash = $state<string | null>(null);
  let hidePoints = $state(false);
  let undoStack = $state<Sam3Point[][]>([]);
  let sam3Available = $state(true);
  let sam3EngineState = $state<'idle' | 'loading' | 'ready' | 'failed'>('idle');
  let sam3Ready = $derived(sam3Available && sam3EngineState === 'ready');
  let imageEl = $state<HTMLImageElement | null>(null);

  // Zoom & pan state
  let zoom = $state(1);
  let panX = $state(0);
  let panY = $state(0);
  let isPanning = $state(false);
  let panStart = $state({ x: 0, y: 0 });
  let viewportEl: HTMLDivElement;
  let imageContainerEl: HTMLDivElement;

  // Rectangle drawing fallback state
  let drawing = $state(false);
  let drawStart = $state<{ x: number; y: number } | null>(null);
  let drawCurrent = $state<{ x: number; y: number } | null>(null);

  // --- Derived values ---

  const activeLabel = $derived(activeLabelId ? localLabels.find(l => l.id === activeLabelId) : undefined);

  const imageAnnotations = $derived(
    selectedHash ? localAnnotations.filter(a => a.imageHash === selectedHash) : []
  );

  const selectedAnnotation = $derived(
    selectedHash && activeLabelId
      ? localAnnotations.find(a => a.imageHash === selectedHash && a.labelId === activeLabelId)
      : undefined
  );

  const annotationMap = $derived(() => {
    const map = new Map<string, Sam3Annotation[]>();
    for (const a of localAnnotations) {
      const arr = map.get(a.imageHash) ?? [];
      arr.push(a);
      map.set(a.imageHash, arr);
    }
    return map;
  });

  const filteredImages = $derived(() => {
    const map = annotationMap();
    return images.filter(img => {
      if (filterLabel === 'all') return true;
      const anns = map.get(img.hash) ?? [];
      if (filterLabel === 'unlabeled') return anns.length === 0;
      return anns.some(a => a.label === filterLabel);
    });
  });

  const annotatedCount = $derived(new Set(localAnnotations.map(a => a.imageHash)).size);
  const goodCount = $derived(
    new Set(localAnnotations.filter(a => a.label === 'good').map(a => a.imageHash)).size
  );
  const anomalyCount = $derived(
    new Set(localAnnotations.filter(a => a.label === 'anomaly').map(a => a.imageHash)).size
  );

  // --- Helpers ---

  function hexToRgba(hex: string, alpha: number): string {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  // --- Label management ---

  function addLabel() {
    if (!newLabelName.trim()) return;
    const color = LABEL_COLORS[localLabels.length % LABEL_COLORS.length];
    localLabels = [...localLabels, {
      id: crypto.randomUUID(),
      name: newLabelName.trim(),
      kind: newLabelKind,
      color,
    }];
    newLabelName = '';
    newLabelKind = 'anomaly';
    addingLabel = false;
  }

  function deleteLabel(labelId: string) {
    localLabels = localLabels.filter(l => l.id !== labelId);
    localAnnotations = localAnnotations.filter(a => a.labelId !== labelId);
    if (activeLabelId === labelId) activeLabelId = null;
  }

  function startEditLabel(label: AnnotationLabel) {
    editingLabelId = label.id;
    editLabelName = label.name;
    editLabelKind = label.kind;
  }

  function saveEditLabel() {
    if (!editingLabelId || !editLabelName.trim()) return;
    localLabels = localLabels.map(l =>
      l.id === editingLabelId ? { ...l, name: editLabelName.trim(), kind: editLabelKind } : l
    );
    localAnnotations = localAnnotations.map(a =>
      a.labelId === editingLabelId ? { ...a, label: editLabelKind } : a
    );
    editingLabelId = null;
  }

  function selectLabelForImage(labelId: string) {
    if (!selectedHash) return;
    const label = localLabels.find(l => l.id === labelId);
    if (!label) return;

    activeLabelId = labelId;

    // Create annotation if it doesn't exist
    const exists = localAnnotations.some(a => a.imageHash === selectedHash && a.labelId === labelId);
    if (!exists) {
      localAnnotations = [...localAnnotations, { imageHash: selectedHash, labelId, label: label.kind }];
    }

    // Reset SAM3 interaction state when switching labels
    currentPoints = [];
    previewMask = null;
    undoStack = [];
  }

  function removeLabelFromImage(labelId: string) {
    if (!selectedHash) return;
    localAnnotations = localAnnotations.filter(
      a => !(a.imageHash === selectedHash && a.labelId === labelId)
    );
    if (activeLabelId === labelId) {
      activeLabelId = null;
      currentPoints = [];
      previewMask = null;
      undoStack = [];
    }
  }

  // --- Data fetching ---

  async function fetchImages() {
    loading = true;
    try {
      const params = new URLSearchParams();
      if (programId != null) params.set('program_id', String(programId));
      if (nodeId) params.set('node_id', nodeId);
      const res = await fetch(`/api/images?${params}`);
      if (res.ok) {
        images = await res.json();
      }
    } catch {
      // ignore
    } finally {
      loading = false;
    }
  }

  async function checkSam3Status() {
    try {
      const res = await fetch('/api/sam3/status');
      if (res.ok) {
        const data = await res.json();
        sam3Available = data.available === true;
        if (data.state) {
          sam3EngineState = data.state;
        }
      } else {
        sam3Available = false;
      }
    } catch {
      sam3Available = false;
    }
  }

  async function triggerSam3Init() {
    try {
      const res = await fetch('/api/sam3/init', { method: 'POST' });
      if (res.status === 409 && ongpuconflict) {
        const data = await res.json().catch(() => ({}));
        await ongpuconflict(data.holder ?? 'pipeline');
        // Retry after user resolved the conflict
        const retry = await fetch('/api/sam3/init', { method: 'POST' });
        if (retry.ok) {
          const retryData = await retry.json();
          sam3EngineState = retryData.state;
        }
        return;
      }
      if (res.ok) {
        const data = await res.json();
        sam3EngineState = data.state;
      }
    } catch {
      // ignore
    }
  }

  async function encodeImage(hash: string) {
    if (encodedHash === hash) return;
    encoding = true;
    try {
      const res = await fetch('/api/sam3/encode', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ image_hash: hash }),
      });
      if (res.ok) {
        encodedHash = hash;
      }
    } catch {
      // ignore
    } finally {
      encoding = false;
    }
  }

  async function segment() {
    if (!selectedHash || currentPoints.length === 0) {
      previewMask = null;
      return;
    }
    segmenting = true;
    try {
      const res = await fetch('/api/sam3/segment', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          image_hash: selectedHash,
          points: currentPoints,
        }),
      });
      if (res.ok) {
        const data = await res.json();
        previewMask = { base64: data.mask, iou: data.iou, detections: data.detections };
      }
    } catch {
      // ignore
    } finally {
      segmenting = false;
    }
  }

  // --- Zoom & pan ---

  // Attach non-passive wheel listener so preventDefault() works
  $effect(() => {
    if (!viewportEl) return;
    const el = viewportEl;
    el.addEventListener('wheel', handleWheel, { passive: false });
    return () => el.removeEventListener('wheel', handleWheel);
  });

  function handleWheel(e: WheelEvent) {
    e.preventDefault();
    if (!imageEl) return;

    const rect = viewportEl.getBoundingClientRect();
    const mx = e.clientX - rect.left - rect.width / 2;
    const my = e.clientY - rect.top - rect.height / 2;

    const oldZoom = zoom;
    const delta = e.deltaY > 0 ? 0.9 : 1.1;
    zoom = Math.max(1, Math.min(20, zoom * delta));

    const scale = zoom / oldZoom;
    panX = mx - scale * (mx - panX);
    panY = my - scale * (my - panY);

    if (zoom === 1) { panX = 0; panY = 0; }
    clampPan();
  }

  function clampPan() {
    if (zoom <= 1) { panX = 0; panY = 0; return; }
    if (!viewportEl) return;
    const rect = viewportEl.getBoundingClientRect();
    const maxPanX = (rect.width * (zoom - 1)) / 2;
    const maxPanY = (rect.height * (zoom - 1)) / 2;
    panX = Math.max(-maxPanX, Math.min(maxPanX, panX));
    panY = Math.max(-maxPanY, Math.min(maxPanY, panY));
  }

  function handlePanStart(e: MouseEvent) {
    if (e.button === 1 || (zoom > 1 && e.button === 0 && e.shiftKey)) {
      e.preventDefault();
      isPanning = true;
      panStart = { x: e.clientX - panX, y: e.clientY - panY };
    }
  }

  function handlePanMove(e: MouseEvent) {
    if (!isPanning) return;
    panX = e.clientX - panStart.x;
    panY = e.clientY - panStart.y;
    clampPan();
  }

  function handlePanEnd() {
    isPanning = false;
  }

  function resetZoom() {
    zoom = 1;
    panX = 0;
    panY = 0;
  }

  // --- SAM3 image interaction ---

  /** Ensure an anomaly label is active; auto-create + select one if needed. */
  function ensureAnomalyLabel(): string {
    let anomalyLabel = localLabels.find(l => l.kind === 'anomaly');
    if (!anomalyLabel) {
      const color = LABEL_COLORS[localLabels.length % LABEL_COLORS.length];
      anomalyLabel = { id: crypto.randomUUID(), name: 'Anomaly', kind: 'anomaly', color };
      localLabels = [...localLabels, anomalyLabel];
    }
    activeLabelId = anomalyLabel.id;
    return anomalyLabel.id;
  }

  function handleImageClick(e: MouseEvent) {
    if (isPanning) return;
    if (!imageEl || !sam3Ready) return;
    if (e.button !== 0 && e.button !== 2) return;
    if (e.shiftKey && zoom > 1) return;

    const rect = imageEl.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    const y = (e.clientY - rect.top) / rect.height;
    if (x < 0 || x > 1 || y < 0 || y > 1) return;

    const label: 0 | 1 = (e.button === 2) ? 1 : (toolMode === 'positive' ? 0 : 1);
    const point: Sam3Point = { x, y, label };

    undoStack = [...undoStack, [...currentPoints]];
    currentPoints = [...currentPoints, point];
    segment();
  }

  function removePoint(idx: number) {
    undoStack = [...undoStack, [...currentPoints]];
    currentPoints = currentPoints.filter((_, i) => i !== idx);
    if (currentPoints.length > 0) {
      segment();
    } else {
      previewMask = null;
    }
  }

  function handleContextMenu(e: Event) {
    e.preventDefault();
  }

  function handleUndo() {
    if (undoStack.length === 0) return;
    const prev = undoStack[undoStack.length - 1];
    undoStack = undoStack.slice(0, -1);
    currentPoints = prev;
    if (currentPoints.length > 0) {
      segment();
    } else {
      previewMask = null;
    }
  }

  function clearPoints() {
    currentPoints = [];
    previewMask = null;
    undoStack = [];
  }

  function acceptMask() {
    if (!previewMask || !selectedHash) return;

    // Auto-ensure an anomaly label exists and is active
    const labelId = ensureAnomalyLabel();

    const mask: Sam3Mask = {
      mask: previewMask.base64,
      iou: previewMask.iou,
      points: [...currentPoints],
      label: maskLabel.trim() || undefined,
    };

    const idx = localAnnotations.findIndex(a => a.imageHash === selectedHash && a.labelId === labelId);
    if (idx >= 0) {
      const ann = localAnnotations[idx];
      localAnnotations[idx] = {
        ...ann,
        masks: [...(ann.masks ?? []), mask],
      };
      localAnnotations = [...localAnnotations];
    } else {
      localAnnotations = [...localAnnotations, {
        imageHash: selectedHash,
        labelId,
        label: 'anomaly' as const,
        masks: [mask],
      }];
    }

    currentPoints = [];
    previewMask = null;
    undoStack = [];
  }

  function removeMask(maskIdx: number) {
    if (!selectedHash || !activeLabelId) return;
    const idx = localAnnotations.findIndex(a => a.imageHash === selectedHash && a.labelId === activeLabelId);
    if (idx < 0) return;
    const ann = localAnnotations[idx];
    const masks = [...(ann.masks ?? [])];
    masks.splice(maskIdx, 1);
    localAnnotations[idx] = { ...ann, masks };
    localAnnotations = [...localAnnotations];
  }

  // --- Rectangle drawing fallback ---

  function addRegion(region: { x: number; y: number; w: number; h: number }) {
    if (!selectedHash) return;
    const labelId = ensureAnomalyLabel();

    const idx = localAnnotations.findIndex(a => a.imageHash === selectedHash && a.labelId === labelId);
    if (idx >= 0) {
      const ann = localAnnotations[idx];
      localAnnotations[idx] = {
        ...ann,
        regions: [...(ann.regions ?? []), region],
      };
      localAnnotations = [...localAnnotations];
    } else {
      localAnnotations = [...localAnnotations, {
        imageHash: selectedHash,
        labelId,
        label: 'anomaly' as const,
        regions: [region],
      }];
    }
  }

  function removeRegion(regionIdx: number) {
    if (!selectedHash || !activeLabelId) return;
    const idx = localAnnotations.findIndex(a => a.imageHash === selectedHash && a.labelId === activeLabelId);
    if (idx < 0) return;
    const ann = localAnnotations[idx];
    const regions = [...(ann.regions ?? [])];
    regions.splice(regionIdx, 1);
    localAnnotations[idx] = { ...ann, regions };
    localAnnotations = [...localAnnotations];
  }

  function getRelativeCoords(e: MouseEvent): { x: number; y: number } | null {
    if (!imageEl) return null;
    const rect = imageEl.getBoundingClientRect();
    return {
      x: (e.clientX - rect.left) / rect.width,
      y: (e.clientY - rect.top) / rect.height,
    };
  }

  function handleMouseDown(e: MouseEvent) {
    if (sam3Ready) return;
    if (e.button !== 0) return;
    const coords = getRelativeCoords(e);
    if (!coords) return;
    drawing = true;
    drawStart = coords;
    drawCurrent = coords;
  }

  function handleMouseMove(e: MouseEvent) {
    if (!drawing) return;
    drawCurrent = getRelativeCoords(e);
  }

  function handleMouseUp(_e: MouseEvent) {
    if (!drawing || !drawStart || !drawCurrent) {
      drawing = false;
      return;
    }
    const x = Math.min(drawStart.x, drawCurrent.x);
    const y = Math.min(drawStart.y, drawCurrent.y);
    const w = Math.abs(drawCurrent.x - drawStart.x);
    const h = Math.abs(drawCurrent.y - drawStart.y);

    if (w > 0.01 && h > 0.01) {
      addRegion({ x, y, w, h });
    }

    drawing = false;
    drawStart = null;
    drawCurrent = null;
  }

  // --- Upload & save ---

  async function handleUpload() {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/jpeg,image/png';
    input.multiple = true;
    input.onchange = async () => {
      if (!input.files) return;
      uploading = true;
      for (const file of input.files) {
        try {
          const formData = new FormData();
          formData.append('image', file);
          if (programId != null) formData.append('program_id', String(programId));
          if (nodeId) formData.append('node_id', nodeId);
          if (cameraId) formData.append('camera_id', cameraId);
          await fetch('/api/images', { method: 'POST', body: formData });
        } catch {
          // ignore individual failures
        }
      }
      uploading = false;
      await fetchImages();
    };
    input.click();
  }

  function handleSave() {
    onsave(localAnnotations, localLabels);
  }

  // --- Keyboard shortcuts ---

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      if (currentPoints.length > 0) {
        clearPoints();
      } else {
        onclose();
      }
      return;
    }

    if (!sam3Ready) {
      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (selectedAnnotation?.regions?.length) {
          removeRegion(selectedAnnotation.regions.length - 1);
        }
      }
      return;
    }
    if (e.key === 'h') { hidePoints = !hidePoints; return; }
    if (e.key === '1' || e.key === 'p') { toolMode = 'positive'; return; }
    if (e.key === '2' || e.key === 'n') { toolMode = 'negative'; return; }
    if (e.key === 'Enter') { acceptMask(); return; }
    if (e.key === 'z' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); handleUndo(); return; }
    if (e.key === 'Delete' || e.key === 'Backspace') {
      if (selectedAnnotation?.masks?.length) {
        removeMask(selectedAnnotation.masks.length - 1);
      }
    }
  }

  // --- Effects ---

  // Reset SAM3 state when selected image changes
  $effect(() => {
    if (selectedHash) {
      const hash = selectedHash;
      currentPoints = [];
      previewMask = null;
      undoStack = [];
      resetZoom();
      encodedHash = null;
      untrack(() => {
        // Auto-select first anomaly label if none active
        if (!activeLabelId) {
          const firstAnomaly = localLabels.find(l => l.kind === 'anomaly');
          if (firstAnomaly) activeLabelId = firstAnomaly.id;
        }
        if (sam3Ready) {
          encodeImage(hash);
        }
      });
    }
  });

  // Auto-encode when SAM3 becomes ready with an image already selected
  $effect(() => {
    if (sam3Ready && selectedHash && encodedHash !== selectedHash) {
      encodeImage(selectedHash);
    }
  });

  $effect(() => {
    untrack(async () => {
      fetchImages();
      await checkSam3Status();
      if (sam3Available && sam3EngineState === 'idle') {
        triggerSam3Init();
      }
    });

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${protocol}//${window.location.host}/ws`);
    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'sam3_status' && msg.state) {
          sam3EngineState = msg.state;
        }
      } catch {
        // ignore non-JSON messages
      }
    };
    return () => ws.close();
  });
</script>

<svelte:window onkeydown={handleKeydown} onmousedown={() => { labelDropdownOpen = false; }} />

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm"
>
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div
    class="w-[calc(100vw-2rem)] h-[calc(100vh-2rem)] bg-zinc-900 border border-border rounded-xl shadow-2xl flex flex-col overflow-hidden"
    onclick={(e) => e.stopPropagation()}
  >
    <!-- Header -->
    <div class="h-12 shrink-0 flex items-center justify-between px-4 border-b border-border">
      <div class="flex items-center gap-2">
        <TagIcon class="size-4 text-amber-400" />
        <span class="text-sm font-semibold text-foreground">Annotation Tool</span>
        <span class="text-xs text-muted-foreground ml-2">
          {images.length} images &middot; {annotatedCount} labeled ({goodCount} good, {anomalyCount} anomaly)
        </span>
        {#if sam3Available}
          {#if sam3EngineState === 'ready'}
            <span class="text-[10px] bg-violet-500/20 text-violet-300 px-1.5 py-0.5 rounded-full ml-1">SAM3</span>
          {:else if sam3EngineState === 'loading'}
            <span class="text-[10px] bg-amber-500/20 text-amber-300 px-1.5 py-0.5 rounded-full ml-1 inline-flex items-center gap-1">
              <LoaderIcon class="size-2.5 animate-spin" />
              SAM3 loading
            </span>
          {:else if sam3EngineState === 'failed'}
            <span class="text-[10px] bg-red-500/20 text-red-300 px-1.5 py-0.5 rounded-full ml-1">SAM3 failed</span>
          {:else}
            <span class="text-[10px] bg-zinc-500/20 text-zinc-400 px-1.5 py-0.5 rounded-full ml-1">SAM3 idle</span>
          {/if}
        {/if}
      </div>
      <div class="flex items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          class="h-7 text-xs bg-zinc-800 border-zinc-700 text-zinc-300"
          onclick={handleUpload}
          disabled={uploading}
        >
          {#if uploading}
            <LoaderIcon class="size-3 animate-spin" />
          {:else}
            <UploadIcon class="size-3" />
          {/if}
          Upload
        </Button>
        <button class="text-muted-foreground hover:text-foreground transition-colors" onclick={onclose}>
          <XIcon class="size-4" />
        </button>
      </div>
    </div>

    <!-- Content -->
    <div class="flex-1 flex overflow-hidden">
      <!-- Left: Image grid -->
      <div class="w-64 shrink-0 flex flex-col border-r border-border">
        <!-- Filter tabs -->
        <div class="flex items-center gap-1 px-2 py-2 border-b border-border">
          {#each ['all', 'good', 'anomaly', 'unlabeled'] as f}
            <button
              class="px-2 py-1 text-[10px] rounded-md transition-colors
                {filterLabel === f ? 'bg-zinc-700 text-zinc-100' : 'text-zinc-500 hover:text-zinc-300'}"
              onclick={() => (filterLabel = f as typeof filterLabel)}
            >
              {f}
            </button>
          {/each}
        </div>

        <!-- Image list -->
        <div class="flex-1 overflow-y-auto p-2 dark-scrollbar">
          {#if loading}
            <div class="flex items-center justify-center py-8">
              <LoaderIcon class="size-5 text-muted-foreground animate-spin" />
            </div>
          {:else if filteredImages().length === 0}
            <div class="flex flex-col items-center justify-center py-8 gap-2">
              <span class="text-xs text-muted-foreground">No images</span>
              <Button
                variant="outline"
                size="sm"
                class="h-7 text-xs"
                onclick={handleUpload}
              >
                <UploadIcon class="size-3" />
                Upload images
              </Button>
            </div>
          {:else}
            <div class="grid grid-cols-3 gap-1">
              {#each filteredImages() as img}
                {@const anns = annotationMap().get(img.hash) ?? []}
                <button
                  class="relative aspect-square rounded overflow-hidden border-2 transition-colors
                    {selectedHash === img.hash ? 'border-primary' : 'border-transparent hover:border-zinc-600'}"
                  onclick={() => (selectedHash = img.hash)}
                >
                  <img
                    src="/api/images/{img.hash}"
                    alt=""
                    class="w-full h-full object-cover"
                    loading="lazy"
                  />
                  {#if anns.length > 0}
                    <div class="absolute top-0.5 right-0.5 flex gap-0.5">
                      {#each anns as ann}
                        {@const lbl = localLabels.find(l => l.id === ann.labelId)}
                        <span
                          class="size-2.5 rounded-full border border-black/30"
                          style="background-color: {lbl?.color ?? (ann.label === 'good' ? '#22c55e' : '#ef4444')}"
                          title={lbl?.name ?? ann.label}
                        ></span>
                      {/each}
                    </div>
                  {/if}
                </button>
              {/each}
            </div>
          {/if}
        </div>
      </div>

      <!-- Center: Selected image with overlay -->
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        bind:this={viewportEl}
        class="flex-1 flex items-center justify-center p-4 bg-zinc-950 overflow-hidden relative"
        onmousedown={handlePanStart}
        onmousemove={handlePanMove}
        onmouseup={handlePanEnd}
        onmouseleave={handlePanEnd}
      >
        {#if selectedHash}
          <div
            bind:this={imageContainerEl}
            class="relative max-w-full max-h-full"
            style="transform: translate({panX}px, {panY}px) scale({zoom}); transform-origin: center center;"
            oncontextmenu={handleContextMenu}
          >
            <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
            <img
              bind:this={imageEl}
              src="/api/images/{selectedHash}"
              alt=""
              class="max-w-full max-h-[calc(100vh-10rem)] object-contain select-none"
              draggable="false"
              onclick={sam3Ready ? handleImageClick : undefined}
              onmousedown={!sam3Ready ? handleMouseDown : undefined}
              onmousemove={!sam3Ready ? handleMouseMove : undefined}
              onmouseup={!sam3Ready ? handleMouseUp : undefined}
              onmouseleave={!sam3Ready ? handleMouseUp : undefined}
            />

            {#if sam3Ready}
              <!-- Accepted masks -->
              {#each selectedAnnotation?.masks ?? [] as mask, i}
                {@const color = maskColor(mask.label, i)}
                <div
                  class="absolute inset-0 w-full h-full pointer-events-none"
                  style="
                    background: {hexToRgba(color, 0.35)};
                    -webkit-mask-image: url('data:image/png;base64,{mask.mask}');
                    mask-image: url('data:image/png;base64,{mask.mask}');
                    -webkit-mask-size: 100% 100%;
                    mask-size: 100% 100%;
                    -webkit-mask-repeat: no-repeat;
                    mask-repeat: no-repeat;
                    -webkit-mask-mode: luminance;
                    mask-mode: luminance;
                  "
                ></div>
              {/each}

              <!-- Preview mask overlay -->
              {#if previewMask}
                {@const previewColor = maskColor(maskLabel || undefined, (selectedAnnotation?.masks?.length ?? 0))}
                <div
                  class="absolute inset-0 w-full h-full pointer-events-none"
                  style="
                    background: {hexToRgba(previewColor, 0.4)};
                    -webkit-mask-image: url('data:image/png;base64,{previewMask.base64}');
                    mask-image: url('data:image/png;base64,{previewMask.base64}');
                    -webkit-mask-size: 100% 100%;
                    mask-size: 100% 100%;
                    -webkit-mask-repeat: no-repeat;
                    mask-repeat: no-repeat;
                    -webkit-mask-mode: luminance;
                    mask-mode: luminance;
                  "
                ></div>
              {/if}

              <!-- Selected detection bounding box only -->
              {#if previewMask?.detections}
                {#each previewMask.detections.filter(d => d.selected) as det}
                  {@const [x1, y1, x2, y2] = det.box}
                  <div
                    class="absolute pointer-events-none border-2 border-violet-500/90"
                    style="left:{x1 * 100}%;top:{y1 * 100}%;width:{(x2 - x1) * 100}%;height:{(y2 - y1) * 100}%"
                  >
                    <span class="absolute -top-4 left-0 text-[9px] font-mono px-0.5 rounded text-violet-300 bg-black/60">
                      {(det.score * 100).toFixed(0)}%
                    </span>
                  </div>
                {/each}
              {/if}

              <!-- Point markers -->
              {#if !hidePoints}
                {#each currentPoints as point, i}
                  <button
                    class="absolute w-3 h-3 rounded-full border-2 border-white shadow-md cursor-pointer hover:opacity-70 transition-opacity
                      {point.label === 0 ? 'bg-green-500' : 'bg-red-500'}"
                    style="left:{point.x * 100}%;top:{point.y * 100}%;transform:translate(-50%,-50%) scale({1/zoom})"
                    onclick={(e) => { e.stopPropagation(); removePoint(i); }}
                  ></button>
                {/each}
              {/if}
            {:else}
              <!-- Rectangle drawing fallback — regions for ALL labels -->
              {#each imageAnnotations as ann}
                {@const lbl = localLabels.find(l => l.id === ann.labelId)}
                {@const color = lbl?.color ?? '#ef4444'}
                {@const isActive = ann.labelId === activeLabelId}
                {#each ann.regions ?? [] as region, i}
                  {#if isActive}
                    <div
                      class="absolute border-2 bg-opacity-20 cursor-pointer hover:bg-opacity-30 group"
                      style="left:{region.x * 100}%;top:{region.y * 100}%;width:{region.w * 100}%;height:{region.h * 100}%;border-color:{color};background:{hexToRgba(color, 0.2)}"
                      role="button"
                      tabindex="-1"
                      onclick={() => removeRegion(i)}
                      onkeydown={(e) => e.key === 'Delete' && removeRegion(i)}
                    >
                      <span class="absolute -top-5 left-0 text-[10px] opacity-0 group-hover:opacity-100" style="color:{color}">click to delete</span>
                    </div>
                  {:else}
                    <div
                      class="absolute border-2 pointer-events-none"
                      style="left:{region.x * 100}%;top:{region.y * 100}%;width:{region.w * 100}%;height:{region.h * 100}%;border-color:{color};background:{hexToRgba(color, 0.15)}"
                    ></div>
                  {/if}
                {/each}
              {/each}
              <!-- Active drawing rectangle -->
              {#if drawing && drawStart && drawCurrent && activeLabel}
                {@const x = Math.min(drawStart.x, drawCurrent.x)}
                {@const y = Math.min(drawStart.y, drawCurrent.y)}
                {@const w = Math.abs(drawCurrent.x - drawStart.x)}
                {@const h = Math.abs(drawCurrent.y - drawStart.y)}
                <div
                  class="absolute border-2 pointer-events-none"
                  style="left:{x * 100}%;top:{y * 100}%;width:{w * 100}%;height:{h * 100}%;border-color:{activeLabel.color};background:{hexToRgba(activeLabel.color, 0.2)}"
                ></div>
              {/if}
            {/if}
          </div>
        {:else}
          <span class="text-sm text-muted-foreground">Select an image to annotate</span>
        {/if}

        <!-- Zoom indicator -->
        {#if zoom > 1}
          <button
            class="absolute top-2 left-2 flex items-center gap-1 bg-black/70 rounded-full px-2 py-0.5 text-[10px] text-zinc-300 hover:text-white cursor-pointer z-10"
            onclick={(e) => { e.stopPropagation(); resetZoom(); }}
          >{zoom.toFixed(1)}x</button>
        {/if}

        <!-- SAM3 loading overlay -->
        {#if sam3EngineState === 'loading'}
          <div class="absolute inset-0 z-20 flex flex-col items-center justify-center bg-black/60 backdrop-blur-sm">
            <LoaderIcon class="size-8 text-violet-400 animate-spin mb-3" />
            <span class="text-sm font-semibold text-zinc-200">Loading SAM3 Engine</span>
            <span class="text-xs text-zinc-500 mt-1">This typically takes 2-5 minutes</span>
            <div class="w-48 h-1 bg-zinc-800 rounded-full mt-3 overflow-hidden">
              <div class="h-full bg-violet-500 rounded-full animate-pulse" style="width: 60%"></div>
            </div>
          </div>
        {/if}

        <!-- Encoding/segmenting indicator -->
        {#if encoding || segmenting}
          <div class="absolute top-2 right-2 flex items-center gap-1.5 bg-black/70 rounded-full px-2.5 py-1 z-10">
            <LoaderIcon class="size-3 text-violet-400 animate-spin" />
            <span class="text-[10px] text-violet-300">{encoding ? 'Encoding...' : 'Segmenting...'}</span>
          </div>
        {/if}
      </div>

      <!-- Right: Annotation controls -->
      <div class="w-56 shrink-0 flex flex-col border-l border-border overflow-y-auto dark-scrollbar">
        {#if selectedHash}
          <div class="p-3 flex flex-col gap-3">
            <!-- Image Label (Good / Anomaly) -->
            <div class="flex flex-col gap-1.5">
              <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Image Label</span>
              <div class="flex gap-1.5">
                {#each localLabels as lbl}
                  {@const isActive = imageAnnotations.some(a => a.labelId === lbl.id)}
                  <button
                    class="flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-md text-[11px] font-medium transition-colors
                      {isActive
                        ? 'ring-1 ring-opacity-50'
                        : 'bg-zinc-800 text-zinc-500 hover:bg-zinc-700 hover:text-zinc-300'}"
                    style={isActive ? `background: ${lbl.color}22; color: ${lbl.color}; --tw-ring-color: ${lbl.color}80` : ''}
                    onclick={() => {
                      if (isActive) {
                        removeLabelFromImage(lbl.id);
                      } else {
                        selectLabelForImage(lbl.id);
                      }
                    }}
                  >
                    <span class="size-2 rounded-full" style="background-color: {lbl.color}"></span>
                    {lbl.name}
                  </button>
                {/each}
              </div>
              <span class="text-[10px] text-zinc-600">Click to toggle good/anomaly classification.</span>
            </div>

            <!-- Divider -->
            <div class="border-t border-border"></div>

            {#if sam3Ready}
              <!-- SAM3 Segment Tool -->
              <div class="flex flex-col gap-1.5">
                <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Segment Tool</span>
                <div class="flex gap-1.5">
                  <button
                    class="flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-md text-[11px] font-medium transition-colors
                      {toolMode === 'positive'
                        ? 'bg-green-600/30 text-green-300 ring-1 ring-green-500/50'
                        : 'bg-zinc-800 text-zinc-500 hover:bg-zinc-700 hover:text-zinc-300'}"
                    onclick={() => (toolMode = 'positive')}
                  >
                    <CirclePlusIcon class="size-3.5" />
                    <span>Include</span>
                  </button>
                  <button
                    class="flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-md text-[11px] font-medium transition-colors
                      {toolMode === 'negative'
                        ? 'bg-red-600/30 text-red-300 ring-1 ring-red-500/50'
                        : 'bg-zinc-800 text-zinc-500 hover:bg-zinc-700 hover:text-zinc-300'}"
                    onclick={() => (toolMode = 'negative')}
                  >
                    <CircleMinusIcon class="size-3.5" />
                    <span>Exclude</span>
                  </button>
                </div>
                <span class="text-[10px] text-zinc-600">Click image to place points. Right-click = exclude.</span>
              </div>

              <!-- Actions -->
              <div class="flex flex-col gap-1.5">
                <div class="flex gap-1.5">
                  <button
                    class="flex-1 flex items-center justify-center gap-1 py-1.5 rounded-md text-[11px] font-medium bg-zinc-800 text-zinc-400 hover:bg-zinc-700 hover:text-zinc-200 transition-colors disabled:opacity-40"
                    onclick={handleUndo}
                    disabled={undoStack.length === 0}
                  >
                    <Undo2Icon class="size-3" />
                    Undo
                  </button>
                  <button
                    class="flex-1 flex items-center justify-center gap-1 py-1.5 rounded-md text-[11px] font-medium bg-zinc-800 text-zinc-400 hover:bg-zinc-700 hover:text-zinc-200 transition-colors disabled:opacity-40"
                    onclick={clearPoints}
                    disabled={currentPoints.length === 0}
                  >
                    <EraserIcon class="size-3" />
                    Clear
                  </button>
                </div>
                <!-- Label dropdown combobox -->
                <div class="relative">
                  <!-- svelte-ignore a11y_no_static_element_interactions -->
                  <button
                    class="w-full flex items-center justify-between px-2 py-1.5 text-xs bg-zinc-800 border rounded transition-colors
                      {labelDropdownOpen ? 'border-violet-500 text-zinc-200' : 'border-zinc-700 text-zinc-200 hover:border-zinc-600'}"
                    onmousedown={(e) => e.stopPropagation()}
                    onclick={() => { labelDropdownOpen = !labelDropdownOpen; labelSearch = ''; }}
                  >
                    <span class={maskLabel ? 'text-zinc-200' : 'text-zinc-500'}>{maskLabel || 'Select label...'}</span>
                    {#if maskLabel}
                      <button
                        class="text-zinc-500 hover:text-zinc-300 ml-1"
                        onclick={(e) => { e.stopPropagation(); maskLabel = ''; }}
                      >
                        <XIcon class="size-3" />
                      </button>
                    {/if}
                  </button>
                  {#if labelDropdownOpen}
                    <!-- svelte-ignore a11y_no_static_element_interactions -->
                    <div
                      class="absolute z-50 top-full left-0 right-0 mt-1 bg-zinc-800 border border-zinc-700 rounded shadow-xl overflow-hidden"
                      onmousedown={(e) => e.stopPropagation()}
                    >
                      <input
                        type="text"
                        bind:value={labelSearch}
                        placeholder="Search or create..."
                        class="w-full px-2 py-1.5 text-xs bg-zinc-900 border-b border-zinc-700 text-zinc-200 placeholder:text-zinc-600 focus:outline-none"
                        onkeydown={handleLabelSearchKeydown}
                        onfocus={() => {}}
                      />
                      <div class="max-h-32 overflow-y-auto dark-scrollbar">
                        {#each filteredMaskLabels() as lbl}
                          <button
                            class="w-full text-left px-2 py-1.5 text-xs transition-colors
                              {lbl === maskLabel ? 'bg-violet-600/20 text-violet-300' : 'text-zinc-300 hover:bg-zinc-700'}"
                            onclick={() => selectMaskLabel(lbl)}
                          >
                            {lbl}
                          </button>
                        {/each}
                        {#if labelSearch.trim() && !existingMaskLabels().some(l => l.toLowerCase() === labelSearch.trim().toLowerCase())}
                          <button
                            class="w-full text-left px-2 py-1.5 text-xs text-violet-400 hover:bg-zinc-700 flex items-center gap-1"
                            onclick={() => selectMaskLabel(labelSearch.trim())}
                          >
                            <PlusIcon class="size-3" />
                            Create "{labelSearch.trim()}"
                          </button>
                        {/if}
                        {#if filteredMaskLabels().length === 0 && !labelSearch.trim()}
                          <div class="px-2 py-2 text-[10px] text-zinc-600 text-center">Type to create a label</div>
                        {/if}
                      </div>
                    </div>
                  {/if}
                </div>
                <button
                  class="w-full py-2 rounded-md text-xs font-semibold transition-colors
                    {previewMask
                      ? 'bg-violet-600 text-white hover:bg-violet-500'
                      : 'bg-zinc-800 text-zinc-600 cursor-not-allowed'}"
                  onclick={acceptMask}
                  disabled={!previewMask}
                >
                  {#if previewMask}
                    Accept Mask (IoU: {previewMask.iou.toFixed(2)})
                  {:else}
                    Accept Mask
                  {/if}
                </button>
              </div>

              <!-- Divider -->
              <div class="border-t border-border"></div>
            {/if}

            <!-- Masks list -->
            {#if selectedAnnotation?.masks?.length}
              <div class="flex flex-col gap-1">
                <span class="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Masks</span>
                {#each selectedAnnotation.masks as mask, i}
                  {@const color = maskColor(mask.label, i)}
                  <div class="flex items-center justify-between px-2 py-1.5 rounded bg-zinc-800 text-[10px]">
                    <div class="flex items-center gap-1.5 min-w-0">
                      <div class="w-2 h-2 rounded-full shrink-0" style="background-color: {color}"></div>
                      {#if mask.label}
                        <span class="text-zinc-200 truncate">{mask.label}</span>
                      {:else}
                        <span class="text-zinc-500 italic">unlabeled</span>
                      {/if}
                      <span class="px-1 py-0.5 rounded text-[9px] shrink-0" style="color: {color}; background: {hexToRgba(color, 0.15)}">
                        {mask.iou.toFixed(2)}
                      </span>
                    </div>
                    <button
                      class="text-zinc-600 hover:text-red-400 transition-colors shrink-0 ml-1"
                      onclick={() => removeMask(i)}
                    >
                      <Trash2Icon class="size-3" />
                    </button>
                  </div>
                {/each}
              </div>
            {/if}

            {#if sam3Ready}
              <!-- Keyboard shortcuts help -->
              <div class="mt-auto pt-3 border-t border-border">
                <div class="text-[10px] text-zinc-600 flex flex-col gap-0.5">
                  <span><kbd class="text-zinc-500">1</kbd>/<kbd class="text-zinc-500">p</kbd> include &middot; <kbd class="text-zinc-500">2</kbd>/<kbd class="text-zinc-500">n</kbd> exclude</span>
                  <span><kbd class="text-zinc-500">Enter</kbd> accept &middot; <kbd class="text-zinc-500">Ctrl+Z</kbd> undo</span>
                  <span><kbd class="text-zinc-500">Esc</kbd> clear / close &middot; <kbd class="text-zinc-500">Right-click</kbd> exclude</span>
                </div>
              </div>
            {/if}
          </div>
        {:else}
          <div class="flex-1 flex items-center justify-center p-4">
            <span class="text-xs text-muted-foreground text-center">Select an image from the left panel</span>
          </div>
        {/if}
      </div>
    </div>

    <!-- Bottom bar -->
    <div class="h-12 shrink-0 flex items-center justify-between px-4 border-t border-border">
      <span class="text-xs text-muted-foreground">
        {images.length} images &middot; {annotatedCount} annotated
      </span>
      <div class="flex items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          class="bg-zinc-800 border-zinc-700 text-zinc-300 hover:bg-zinc-700"
          onclick={onclose}
        >
          Cancel
        </Button>
        <Button size="sm" onclick={handleSave}>
          Save & Close
        </Button>
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
  kbd {
    font-family: inherit;
    font-weight: 500;
  }
</style>
