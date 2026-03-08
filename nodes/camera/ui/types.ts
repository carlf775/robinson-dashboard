export interface CameraNodeData extends Record<string, unknown> {
  cameraId: string;
  label: string;
  status: 'disconnected' | 'connected' | 'streaming';
  vendor?: string;
  model?: string;
  serialNumber?: string;
  userName?: string;
  settings?: Record<string, number | string | boolean>;
  onDataChange?: (nodeId: string, newData: Partial<CameraNodeData>) => void;
  onDiscover?: (nodeId: string) => void;
  onSettings?: (nodeId: string) => void;
}

export interface DiscoveredCamera {
  id: string;
  vendor: string;
  model: string;
  serial_number: string;
  user_name: string;
  mac_address: string;
  protocol: string;
}
