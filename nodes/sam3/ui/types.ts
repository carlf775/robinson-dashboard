export type Sam3State = 'needs_data' | 'collecting' | 'annotating' | 'ready_to_train' | 'training' | 'ready';

export interface Sam3Point {
  x: number;
  y: number;
  label: 0 | 1;
}

export interface Sam3Mask {
  mask: string;
  iou: number;
  points: Sam3Point[];
  label?: string;
}

export interface AnnotationLabel {
  id: string;
  name: string;
  kind: 'anomaly' | 'good';
  color: string;
}

export interface Sam3Annotation {
  imageHash: string;
  labelId?: string;
  label: 'good' | 'anomaly';
  masks?: Sam3Mask[];
  regions?: { x: number; y: number; w: number; h: number }[];
}

export interface Sam3NodeData extends Record<string, unknown> {
  label: string;
  state: Sam3State;
  modelId?: string;
  labels?: AnnotationLabel[];
  annotations: Sam3Annotation[];
  predictions?: Sam3Prediction[];
  trainingConfig: { epochs: number; imageSize: number; patience: number };
  inferenceThreshold?: number;
  imageCount?: number;
  collectionError?: string;
  isStartingPipeline?: boolean;
  onStateChange?: (nodeId: string, state: Sam3State) => void;
  onOpenAnnotator?: (nodeId: string) => void;
  onTrain?: (nodeId: string) => void;
  onDataChange?: (nodeId: string, newData: Partial<Sam3NodeData>) => void;
}

export interface Sam3Detection {
  box: [number, number, number, number];
  score: number;
  mask?: string;
  label?: string;
}

export interface Sam3Prediction {
  imageHash: string;
  detections: Sam3Detection[];
}
