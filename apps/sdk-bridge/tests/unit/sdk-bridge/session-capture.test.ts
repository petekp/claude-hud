import { describe, it, expect, vi } from 'vitest';
import { SessionCapture } from '../../../src/sdk-bridge/index.js';

describe('SessionCapture', () => {
  it('should capture session ID from init message', async () => {
    const mockMessages = [
      { type: 'system', subtype: 'init', session_id: 'sess_abc123' },
      { type: 'assistant', content: [{ text: 'Hello' }] },
    ];

    const capture = new SessionCapture();
    for (const msg of mockMessages) {
      capture.processMessage(msg as any);
    }

    expect(capture.sessionId).toBe('sess_abc123');
  });

  it('should handle missing session ID gracefully', async () => {
    const mockMessages = [
      { type: 'assistant', content: [{ text: 'Hello' }] },
      { type: 'result', result: 'Done' },
    ];

    const capture = new SessionCapture();
    for (const msg of mockMessages) {
      capture.processMessage(msg as any);
    }

    expect(capture.sessionId).toBeUndefined();
    expect(capture.hasSession).toBe(false);
  });

  it('should emit event when session ID captured', async () => {
    const onCapture = vi.fn();
    const capture = new SessionCapture();
    capture.onSessionCaptured(onCapture);

    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'sess_xyz' } as any);

    expect(onCapture).toHaveBeenCalledWith('sess_xyz');
  });

  it('should only capture first session ID', async () => {
    const capture = new SessionCapture();

    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'first' } as any);
    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'second' } as any);

    expect(capture.sessionId).toBe('first');
  });

  it('should indicate hasSession is true after capture', () => {
    const capture = new SessionCapture();

    expect(capture.hasSession).toBe(false);

    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'sess_123' } as any);

    expect(capture.hasSession).toBe(true);
  });

  it('should call multiple listeners when session captured', () => {
    const listener1 = vi.fn();
    const listener2 = vi.fn();
    const capture = new SessionCapture();

    capture.onSessionCaptured(listener1);
    capture.onSessionCaptured(listener2);
    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'sess_multi' } as any);

    expect(listener1).toHaveBeenCalledWith('sess_multi');
    expect(listener2).toHaveBeenCalledWith('sess_multi');
  });

  it('should not call listeners on subsequent messages', () => {
    const listener = vi.fn();
    const capture = new SessionCapture();

    capture.onSessionCaptured(listener);
    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'sess_once' } as any);
    capture.processMessage({ type: 'assistant', content: [] } as any);
    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'sess_twice' } as any);

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenCalledWith('sess_once');
  });

  it('should handle system messages without session_id', () => {
    const capture = new SessionCapture();

    capture.processMessage({ type: 'system', subtype: 'other' } as any);

    expect(capture.sessionId).toBeUndefined();
    expect(capture.hasSession).toBe(false);
  });

  it('should reset state when reset is called', () => {
    const capture = new SessionCapture();

    capture.processMessage({ type: 'system', subtype: 'init', session_id: 'sess_reset' } as any);
    expect(capture.hasSession).toBe(true);

    capture.reset();

    expect(capture.sessionId).toBeUndefined();
    expect(capture.hasSession).toBe(false);
  });
});
