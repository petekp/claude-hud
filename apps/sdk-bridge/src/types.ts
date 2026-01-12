export type Language = 'typescript' | 'python' | 'rust' | 'go' | 'javascript';

export interface ProjectPreferences {
  language?: Language;
  framework?: string;
}

export interface CreateProjectInput {
  name: string;
  location: string;
}

export interface CreateProjectResult {
  success: boolean;
  path: string;
  error?: string;
}

export interface GenerateClaudeMdInput {
  name: string;
  description: string;
  preferences?: ProjectPreferences;
}

export interface BuildPromptInput {
  name: string;
  description: string;
  preferences?: ProjectPreferences;
}

export enum ProgressPhase {
  Setup = 'setup',
  Dependencies = 'dependencies',
  Building = 'building',
  Testing = 'testing',
  Thinking = 'thinking',
  Complete = 'complete',
}

export interface ProgressDetails {
  tool?: string;
  file?: string;
  packages?: string[];
}

export interface ProgressInfo {
  phase: ProgressPhase;
  message?: string;
  percentComplete?: number;
  details?: ProgressDetails;
}

export interface ToolUseMessage {
  type: 'tool_use';
  name: string;
  input: Record<string, unknown>;
}

export interface AssistantMessage {
  type: 'assistant';
  content: Array<{ type: string; text?: string }>;
}

export interface SystemMessage {
  type: 'system';
  subtype?: string;
  session_id?: string;
}

export interface ResultMessage {
  type: 'result';
  result: string;
}

export type SdkMessage = ToolUseMessage | AssistantMessage | SystemMessage | ResultMessage;

export interface ParseProgressOptions {
  messageIndex?: number;
  totalEstimate?: number;
}

export enum CreationStatus {
  Pending = 'pending',
  InProgress = 'in_progress',
  Completed = 'completed',
  Failed = 'failed',
  Cancelled = 'cancelled',
}

export interface CreationProgress {
  phase: string;
  message: string;
  percentComplete?: number;
}

export interface ProjectCreation {
  id: string;
  name: string;
  path: string;
  description: string;
  status: CreationStatus;
  sessionId?: string;
  progress?: CreationProgress;
  error?: string;
  createdAt: Date;
  completedAt?: Date;
}

export interface ProjectInfo {
  name: string;
  path: string;
  description: string;
}

export interface CreateProjectFromIdeaRequest {
  name: string;
  description: string;
  location: string;
  preferences?: ProjectPreferences;
}

export interface CreateProjectFromIdeaResult {
  success: boolean;
  projectPath: string;
  sessionId?: string;
  error?: string;
}

export type ProgressCallback = (update: ProgressInfo) => void;
