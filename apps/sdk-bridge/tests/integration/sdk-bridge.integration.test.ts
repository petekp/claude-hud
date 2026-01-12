import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { SdkBridge } from '../../src/sdk-bridge/index.js';

const SKIP_SDK_TESTS = !process.env.SDK_BRIDGE_URL;

describe.skipIf(SKIP_SDK_TESTS)('SdkBridge Integration', () => {
  let bridge: SdkBridge;

  beforeAll(async () => {
    bridge = new SdkBridge(process.env.SDK_BRIDGE_URL!);
    await bridge.connect();
  });

  afterAll(async () => {
    await bridge.disconnect();
  });

  it('should send query and receive response', async () => {
    const prompt = 'What is 2 + 2? Reply with just the number.';

    const messages: any[] = [];
    for await (const msg of bridge.query({ prompt, options: { maxTurns: 1 } })) {
      messages.push(msg);
    }

    expect(messages.length).toBeGreaterThan(0);
    const resultMsg = messages.find(m => m.type === 'result');
    expect(resultMsg).toBeDefined();
    expect(resultMsg.result).toContain('4');
  });

  it('should capture session ID', async () => {
    const prompt = 'Say hello';

    let sessionId: string | undefined;
    for await (const msg of bridge.query({ prompt, options: { maxTurns: 1 } })) {
      if (msg.type === 'system' && msg.subtype === 'init') {
        sessionId = msg.session_id;
      }
    }

    expect(sessionId).toBeDefined();
    expect(sessionId).toMatch(/^sess_/);
  });

  it('should support cancellation', async () => {
    const controller = new AbortController();
    const prompt = 'Count from 1 to 1000, one number per line';
    const messages: any[] = [];

    setTimeout(() => controller.abort(), 1000);

    try {
      for await (const msg of bridge.query({
        prompt,
        options: { signal: controller.signal }
      })) {
        messages.push(msg);
      }
    } catch (e: any) {
      expect(e.name).toBe('AbortError');
    }

    expect(messages.length).toBeLessThan(100);
  });

  it('should resume session', async () => {
    let sessionId: string | undefined;
    for await (const msg of bridge.query({
      prompt: 'Remember the number 42',
      options: { maxTurns: 1 }
    })) {
      if (msg.type === 'system' && msg.subtype === 'init') {
        sessionId = msg.session_id;
      }
    }

    const messages: any[] = [];
    for await (const msg of bridge.query({
      prompt: 'What number did I ask you to remember?',
      options: { resume: sessionId, maxTurns: 1 }
    })) {
      messages.push(msg);
    }

    const result = messages.find(m => m.type === 'result');
    expect(result?.result).toContain('42');
  });
});

describe('SdkBridge Unit Tests', () => {
  it('should be instantiable with CLI path', () => {
    const bridge = new SdkBridge('/opt/homebrew/bin/claude');
    expect(bridge).toBeDefined();
  });

  it('should throw for HTTP URLs (not yet implemented)', () => {
    expect(() => new SdkBridge('http://localhost:3000')).toThrow(
      'HTTP-based SDK bridge not yet implemented'
    );
  });
});
