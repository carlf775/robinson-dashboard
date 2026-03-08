import BrainIcon from '@lucide/svelte/icons/brain';
import Sam3Node from './Sam3Node.svelte';
import Sam3InferencePanel from './Sam3InferencePanel.svelte';
import type { ModuleManifest } from '$lib/modules/types';
import type { Sam3NodeData, Sam3State, AnnotationLabel, Sam3Annotation } from './types';

export default {
  nodeType: 'sam3_ad',
  label: 'SAM3 AD',
  icon: BrainIcon,
  category: 'Processing',
  nodeComponent: Sam3Node,
  runPanel: Sam3InferencePanel,
  transientKeys: ['onStateChange', 'onOpenAnnotator', 'onTrain', 'onDataChange', 'collectionError', 'isStartingPipeline'],
  createDefaultData: (nodeId: number): Record<string, unknown> => ({
    label: `SAM3 AD ${nodeId}`,
    state: 'needs_data' as Sam3State,
    labels: [] as AnnotationLabel[],
    annotations: [] as Sam3Annotation[],
    trainingConfig: { epochs: 100, imageSize: 504, patience: 0 },
  } satisfies Omit<Sam3NodeData, 'onStateChange' | 'onOpenAnnotator' | 'onTrain' | 'onDataChange'>),
} satisfies ModuleManifest;
