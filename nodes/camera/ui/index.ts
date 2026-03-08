import CameraIcon from '@lucide/svelte/icons/camera';
import CameraNode from './CameraNode.svelte';
import CameraFeedPanel from './CameraFeedPanel.svelte';
import type { ModuleManifest } from '$lib/modules/types';
import type { CameraNodeData } from './types';

export default {
  nodeType: 'camera',
  label: 'Camera',
  icon: CameraIcon,
  category: 'Input',
  nodeComponent: CameraNode,
  runPanel: CameraFeedPanel,
  transientKeys: ['onDataChange', 'onDiscover', 'onSettings'],
  createDefaultData: (nodeId: number): Record<string, unknown> => ({
    cameraId: '',
    label: `Camera ${nodeId}`,
    status: 'disconnected',
  } satisfies Omit<CameraNodeData, 'onDataChange' | 'onDiscover' | 'onSettings'>),
} satisfies ModuleManifest;
