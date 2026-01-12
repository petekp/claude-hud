import { writeFile } from 'fs/promises';
import { join } from 'path';
import type {
  CreateProjectFromIdeaRequest,
  CreateProjectFromIdeaResult,
  ProgressCallback,
  ProgressInfo,
  SdkMessage,
} from '../types.js';
import { ProgressPhase } from '../types.js';
import { createProjectDirectory } from './create-project-directory.js';
import { generateClaudeMd } from './generate-claude-md.js';
import { buildCreationPrompt } from './build-prompt.js';
import { parseProgressFromMessage } from './parse-progress.js';
import { SdkBridge } from '../sdk-bridge/sdk-bridge.js';
import { SessionCapture } from '../sdk-bridge/session-capture.js';

export interface CreateProjectOptions {
  dryRun?: boolean;
  claudePath?: string;
}

const DEFAULT_CLAUDE_PATH = '/opt/homebrew/bin/claude';
const ESTIMATED_MESSAGES = 50;

function isSystemMessage(msg: SdkMessage): msg is { type: 'system'; subtype?: string; session_id?: string } {
  return msg.type === 'system';
}

function isResultMessage(msg: SdkMessage): msg is { type: 'result'; result: string } {
  return msg.type === 'result';
}

export async function createProjectFromIdea(
  request: CreateProjectFromIdeaRequest,
  onProgress: ProgressCallback,
  options?: CreateProjectOptions
): Promise<CreateProjectFromIdeaResult> {
  const { name, description, location, preferences } = request;
  const dryRun = options?.dryRun ?? false;
  const claudePath = options?.claudePath ?? DEFAULT_CLAUDE_PATH;

  const emitProgress = (info: ProgressInfo) => {
    try {
      onProgress(info);
    } catch {
      // Ignore progress callback errors
    }
  };

  emitProgress({
    phase: ProgressPhase.Setup,
    message: 'Creating project directory...',
    percentComplete: 5,
  });

  const dirResult = await createProjectDirectory({ name, location });

  if (!dirResult.success) {
    return {
      success: false,
      projectPath: dirResult.path,
      error: dirResult.error,
    };
  }

  const projectPath = dirResult.path;

  emitProgress({
    phase: ProgressPhase.Setup,
    message: 'Generating CLAUDE.md...',
    percentComplete: 10,
  });

  const claudeMdContent = generateClaudeMd({
    name,
    description,
    preferences,
  });

  await writeFile(join(projectPath, 'CLAUDE.md'), claudeMdContent);

  if (dryRun) {
    emitProgress({
      phase: ProgressPhase.Complete,
      message: 'Dry run complete',
      percentComplete: 100,
    });

    return {
      success: true,
      projectPath,
    };
  }

  emitProgress({
    phase: ProgressPhase.Building,
    message: 'Starting Claude to build project...',
    percentComplete: 15,
  });

  const prompt = buildCreationPrompt({ name, description, preferences });
  const bridge = new SdkBridge(claudePath);
  const sessionCapture = new SessionCapture();

  let messageIndex = 0;

  try {
    for await (const message of bridge.query({
      prompt,
      workingDirectory: projectPath,
    })) {
      sessionCapture.processMessage(message);

      if (isSystemMessage(message) && message.subtype === 'init') {
        emitProgress({
          phase: ProgressPhase.Building,
          message: 'Claude session started',
          percentComplete: 20,
        });
        continue;
      }

      if (isResultMessage(message)) {
        emitProgress({
          phase: ProgressPhase.Complete,
          message: 'Project creation complete',
          percentComplete: 100,
        });
        break;
      }

      const progressInfo = parseProgressFromMessage(message, {
        messageIndex,
        totalEstimate: ESTIMATED_MESSAGES,
      });

      const scaledPercent = progressInfo.percentComplete
        ? Math.min(95, 20 + (progressInfo.percentComplete * 0.75))
        : undefined;

      emitProgress({
        ...progressInfo,
        percentComplete: scaledPercent,
      });

      messageIndex++;
    }

    return {
      success: true,
      projectPath,
      sessionId: sessionCapture.sessionId,
    };
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);

    emitProgress({
      phase: ProgressPhase.Building,
      message: `Build failed: ${errorMessage}`,
      percentComplete: undefined,
    });

    return {
      success: false,
      projectPath,
      sessionId: sessionCapture.sessionId,
      error: errorMessage,
    };
  } finally {
    await bridge.disconnect();
  }
}
