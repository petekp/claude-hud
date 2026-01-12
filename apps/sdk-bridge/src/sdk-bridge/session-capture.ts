import type { SdkMessage, SystemMessage } from '../types.js';

function isSystemMessage(message: SdkMessage): message is SystemMessage {
  return message.type === 'system';
}

export class SessionCapture {
  private _sessionId?: string;
  private _listeners: Array<(sessionId: string) => void> = [];

  get sessionId(): string | undefined {
    return this._sessionId;
  }

  get hasSession(): boolean {
    return this._sessionId !== undefined;
  }

  processMessage(message: SdkMessage): void {
    if (this._sessionId) {
      return;
    }

    if (isSystemMessage(message) && message.subtype === 'init' && message.session_id) {
      this._sessionId = message.session_id;
      this._notifyListeners();
    }
  }

  onSessionCaptured(callback: (sessionId: string) => void): void {
    this._listeners.push(callback);
  }

  reset(): void {
    this._sessionId = undefined;
  }

  private _notifyListeners(): void {
    if (this._sessionId) {
      for (const listener of this._listeners) {
        listener(this._sessionId);
      }
    }
  }
}
