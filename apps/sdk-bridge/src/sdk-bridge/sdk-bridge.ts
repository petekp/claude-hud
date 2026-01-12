import { spawn, type ChildProcess } from 'child_process';
import { createInterface } from 'readline';
import type { SdkMessage } from '../types.js';

export interface QueryOptions {
  prompt: string;
  workingDirectory?: string;
  options?: {
    maxTurns?: number;
    resume?: string;
    signal?: AbortSignal;
  };
}

export interface SdkBridgeConfig {
  claudePath?: string;
}

export class SdkBridge {
  private claudePath: string;
  private activeProcess: ChildProcess | null = null;

  constructor(claudePathOrUrl: string) {
    if (claudePathOrUrl.startsWith('http')) {
      throw new Error('HTTP-based SDK bridge not yet implemented. Use local Claude CLI path.');
    }
    this.claudePath = claudePathOrUrl || '/opt/homebrew/bin/claude';
  }

  async connect(): Promise<void> {
    // For CLI-based bridge, no persistent connection needed
  }

  async disconnect(): Promise<void> {
    if (this.activeProcess) {
      this.activeProcess.kill();
      this.activeProcess = null;
    }
  }

  async *query(options: QueryOptions): AsyncGenerator<SdkMessage> {
    const args = ['--output-format', 'stream-json', '--print', options.prompt];

    if (options.options?.maxTurns !== undefined) {
      args.push('--max-turns', String(options.options.maxTurns));
    }

    if (options.options?.resume) {
      args.push('--resume', options.options.resume);
    }

    const cwd = options.workingDirectory || process.cwd();

    const proc = spawn(this.claudePath, args, {
      cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, FORCE_COLOR: '0' },
    });

    this.activeProcess = proc;

    if (options.options?.signal) {
      options.options.signal.addEventListener('abort', () => {
        proc.kill();
      });
    }

    const rl = createInterface({
      input: proc.stdout,
      crlfDelay: Infinity,
    });

    const messageQueue: SdkMessage[] = [];
    let resolveNext: ((value: IteratorResult<SdkMessage>) => void) | null = null;
    let done = false;
    let error: Error | null = null;

    rl.on('line', (line) => {
      if (!line.trim()) return;

      try {
        const message = JSON.parse(line) as SdkMessage;
        if (resolveNext) {
          const resolve = resolveNext;
          resolveNext = null;
          resolve({ value: message, done: false });
        } else {
          messageQueue.push(message);
        }
      } catch {
        // Skip non-JSON lines (e.g., progress indicators)
      }
    });

    proc.stderr.on('data', (data) => {
      const text = data.toString();
      if (text.includes('Error') || text.includes('error')) {
        error = new Error(text);
      }
    });

    proc.on('close', () => {
      done = true;
      this.activeProcess = null;
      rl.close();

      if (resolveNext) {
        const resolve = resolveNext;
        resolveNext = null;
        if (error) {
          resolve({ value: undefined as unknown as SdkMessage, done: true });
        } else {
          resolve({ value: undefined as unknown as SdkMessage, done: true });
        }
      }
    });

    proc.on('error', (err) => {
      error = err;
      done = true;
      if (resolveNext) {
        const resolve = resolveNext;
        resolveNext = null;
        resolve({ value: undefined as unknown as SdkMessage, done: true });
      }
    });

    while (true) {
      if (options.options?.signal?.aborted) {
        const abortError = new Error('Aborted');
        abortError.name = 'AbortError';
        throw abortError;
      }

      if (messageQueue.length > 0) {
        yield messageQueue.shift()!;
        continue;
      }

      if (done) {
        if (error) {
          throw error;
        }
        return;
      }

      const message = await new Promise<IteratorResult<SdkMessage>>((resolve) => {
        if (messageQueue.length > 0) {
          resolve({ value: messageQueue.shift()!, done: false });
        } else if (done) {
          resolve({ value: undefined as unknown as SdkMessage, done: true });
        } else {
          resolveNext = resolve;
        }
      });

      if (message.done) {
        return;
      }

      yield message.value;
    }
  }
}
