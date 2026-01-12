import { describe, it, expect } from 'vitest';
import { parseProgressFromMessage, ProgressPhase } from '../../../src/project-creator/index.js';
import type { ToolUseMessage, AssistantMessage } from '../../../src/types.js';

describe('parseProgressFromMessage', () => {
  it('should identify setup phase from directory creation', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'mkdir -p src' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Setup);
  });

  it('should identify building phase from file writes', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Write',
      input: { file_path: '/project/src/index.ts' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Building);
  });

  it('should identify dependencies phase from npm install', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'npm install commander marked' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Dependencies);
  });

  it('should identify dependencies phase from pip install', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'pip install requests flask' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Dependencies);
  });

  it('should identify testing phase from test commands', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'npm test' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Testing);
  });

  it('should identify testing phase from pytest', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'pytest tests/' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Testing);
  });

  it('should extract file path from Write tool', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Write',
      input: { file_path: '/project/src/cli.ts', content: '...' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.details?.file).toBe('src/cli.ts');
  });

  it('should extract package names from npm install', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'npm install express cors helmet' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.details?.packages).toEqual(['express', 'cors', 'helmet']);
  });

  it('should handle thinking/assistant messages', () => {
    const message: AssistantMessage = {
      type: 'assistant',
      content: [{ type: 'text', text: 'Let me create the main entry point...' }],
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Thinking);
    expect(progress.message).toContain('entry point');
  });

  it('should estimate completion percentage', () => {
    const messages = [
      { type: 'tool_use' as const, name: 'Bash', input: { command: 'npm init -y' } },
      { type: 'tool_use' as const, name: 'Write', input: { file_path: 'package.json' } },
      { type: 'tool_use' as const, name: 'Bash', input: { command: 'npm install' } },
      { type: 'tool_use' as const, name: 'Write', input: { file_path: 'src/index.ts' } },
      { type: 'tool_use' as const, name: 'Write', input: { file_path: 'src/cli.ts' } },
      { type: 'tool_use' as const, name: 'Bash', input: { command: 'npm test' } },
    ];

    const progressValues = messages.map((m, i) =>
      parseProgressFromMessage(m, { messageIndex: i, totalEstimate: 10 })
    );

    expect(progressValues[0].percentComplete).toBeLessThan(progressValues[5].percentComplete!);
    expect(progressValues[5].percentComplete).toBeGreaterThanOrEqual(50);
  });

  it('should handle Read tool as building phase', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Read',
      input: { file_path: '/project/src/config.ts' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Building);
  });

  it('should handle Edit tool as building phase', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Edit',
      input: { file_path: '/project/src/index.ts', old_string: 'foo', new_string: 'bar' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.phase).toBe(ProgressPhase.Building);
  });

  it('should extract tool name in details', () => {
    const message: ToolUseMessage = {
      type: 'tool_use',
      name: 'Write',
      input: { file_path: '/project/README.md' },
    };

    const progress = parseProgressFromMessage(message);

    expect(progress.details?.tool).toBe('Write');
  });

  it('should handle unknown message types gracefully', () => {
    const message = {
      type: 'unknown',
      data: 'some data',
    };

    const progress = parseProgressFromMessage(message as any);

    expect(progress.phase).toBe(ProgressPhase.Thinking);
  });
});
