import type { SdkMessage, ProgressInfo, ParseProgressOptions, ToolUseMessage, AssistantMessage } from '../types.js';
import { ProgressPhase } from '../types.js';

export { ProgressPhase };

function isToolUseMessage(message: SdkMessage): message is ToolUseMessage {
  return message.type === 'tool_use';
}

function isAssistantMessage(message: SdkMessage): message is AssistantMessage {
  return message.type === 'assistant';
}

function extractFileName(filePath: string): string {
  const parts = filePath.split('/');
  const startIndex = parts.findIndex(p => p === 'src' || p === 'lib' || p === 'test' || p === 'tests');
  if (startIndex !== -1) {
    return parts.slice(startIndex).join('/');
  }
  return parts[parts.length - 1];
}

function parsePackagesFromCommand(command: string): string[] | undefined {
  const npmMatch = command.match(/npm install\s+(.+)/);
  if (npmMatch) {
    return npmMatch[1]
      .split(/\s+/)
      .filter(p => !p.startsWith('-'))
      .filter(Boolean);
  }

  const pipMatch = command.match(/pip install\s+(.+)/);
  if (pipMatch) {
    return pipMatch[1]
      .split(/\s+/)
      .filter(p => !p.startsWith('-'))
      .filter(Boolean);
  }

  return undefined;
}

function isSetupCommand(command: string): boolean {
  return (
    command.includes('mkdir') ||
    command.includes('npm init') ||
    command.includes('cargo init') ||
    command.includes('git init') ||
    command.includes('touch')
  );
}

function isDependencyCommand(command: string): boolean {
  return (
    command.includes('npm install') ||
    command.includes('pip install') ||
    command.includes('cargo add') ||
    command.includes('pnpm install') ||
    command.includes('yarn add')
  );
}

function isTestCommand(command: string): boolean {
  return (
    command.includes('npm test') ||
    command.includes('npm run test') ||
    command.includes('pytest') ||
    command.includes('cargo test') ||
    command.includes('vitest') ||
    command.includes('jest')
  );
}

function getPhaseFromBashCommand(command: string): ProgressPhase {
  if (isTestCommand(command)) {
    return ProgressPhase.Testing;
  }
  if (isDependencyCommand(command)) {
    return ProgressPhase.Dependencies;
  }
  if (isSetupCommand(command)) {
    return ProgressPhase.Setup;
  }
  return ProgressPhase.Building;
}

function calculatePercentComplete(options: ParseProgressOptions | undefined): number | undefined {
  if (options?.messageIndex === undefined || !options?.totalEstimate) {
    return undefined;
  }
  const percent = Math.round((options.messageIndex / options.totalEstimate) * 100);
  return Math.min(percent, 99);
}

export function parseProgressFromMessage(
  message: SdkMessage,
  options?: ParseProgressOptions
): ProgressInfo {
  const percentComplete = calculatePercentComplete(options);

  if (isToolUseMessage(message)) {
    const { name, input } = message;

    if (name === 'Bash') {
      const command = input.command as string;
      const phase = getPhaseFromBashCommand(command);
      const packages = parsePackagesFromCommand(command);

      return {
        phase,
        details: {
          tool: name,
          packages,
        },
        percentComplete,
      };
    }

    if (name === 'Write' || name === 'Edit' || name === 'Read') {
      const filePath = input.file_path as string;

      return {
        phase: ProgressPhase.Building,
        details: {
          tool: name,
          file: filePath ? extractFileName(filePath) : undefined,
        },
        percentComplete,
      };
    }

    return {
      phase: ProgressPhase.Building,
      details: {
        tool: name,
      },
      percentComplete,
    };
  }

  if (isAssistantMessage(message)) {
    const textContent = message.content?.find(c => c.type === 'text');
    const text = textContent?.text || '';

    return {
      phase: ProgressPhase.Thinking,
      message: text,
      percentComplete,
    };
  }

  return {
    phase: ProgressPhase.Thinking,
    percentComplete,
  };
}
