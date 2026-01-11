/**
 * Relay client - pushes state updates to relay server for remote clients
 * This is a placeholder implementation - full relay integration can be added later
 */

import type { SDKMessage, SDKResultMessage } from '../sdk/types.js'
import type { SessionState } from './state.js'
import { logDebug } from '../sdk/utils.js'

export interface RelayState {
    cwd: string
    thinking: boolean
    state: SessionState
    sessionId: string | null
    model: string | null
    timestamp: number
}

export interface RelayClientOptions {
    url?: string
    projectId?: string
    enabled?: boolean
}

export interface RelayClient {
    pushState(state: RelayState): void
    pushMessage(message: SDKMessage): void
    pushResult(result: SDKResultMessage): void
    connect(): Promise<void>
    disconnect(): void
}

export class NoopRelayClient implements RelayClient {
    pushState(_state: RelayState): void {
        // No-op
    }

    pushMessage(_message: SDKMessage): void {
        // No-op
    }

    pushResult(_result: SDKResultMessage): void {
        // No-op
    }

    async connect(): Promise<void> {
        // No-op
    }

    disconnect(): void {
        // No-op
    }
}

export class WebSocketRelayClient implements RelayClient {
    private ws: WebSocket | null = null
    private url: string
    private projectId: string
    private reconnectAttempts = 0
    private maxReconnectAttempts = 5
    private reconnectDelay = 1000

    constructor(options: RelayClientOptions) {
        this.url = options.url || 'ws://localhost:8080'
        this.projectId = options.projectId || 'unknown'
    }

    async connect(): Promise<void> {
        return new Promise((resolve, reject) => {
            try {
                this.ws = new WebSocket(this.url)

                this.ws.onopen = () => {
                    logDebug(`Connected to relay at ${this.url}`)
                    this.reconnectAttempts = 0
                    this.sendAuth()
                    resolve()
                }

                this.ws.onclose = () => {
                    logDebug('Relay connection closed')
                    this.scheduleReconnect()
                }

                this.ws.onerror = (error) => {
                    logDebug(`Relay error: ${error}`)
                    reject(error)
                }

                this.ws.onmessage = (event) => {
                    this.handleMessage(event.data as string)
                }
            } catch (error) {
                reject(error)
            }
        })
    }

    disconnect(): void {
        if (this.ws) {
            this.ws.close()
            this.ws = null
        }
    }

    pushState(state: RelayState): void {
        this.send({
            type: 'state_update',
            projectId: this.projectId,
            ...state
        })
    }

    pushMessage(message: SDKMessage): void {
        this.send({
            type: 'message',
            projectId: this.projectId,
            message
        })
    }

    pushResult(result: SDKResultMessage): void {
        this.send({
            type: 'result',
            projectId: this.projectId,
            result
        })
    }

    private send(data: unknown): void {
        if (this.ws?.readyState === WebSocket.OPEN) {
            this.ws.send(JSON.stringify(data))
        }
    }

    private sendAuth(): void {
        this.send({
            type: 'auth',
            projectId: this.projectId
        })
    }

    private handleMessage(data: string): void {
        try {
            const message = JSON.parse(data)
            logDebug(`Relay message: ${message.type}`)
        } catch {
            logDebug('Failed to parse relay message')
        }
    }

    private scheduleReconnect(): void {
        if (this.reconnectAttempts >= this.maxReconnectAttempts) {
            logDebug('Max reconnect attempts reached')
            return
        }

        this.reconnectAttempts++
        const delay = this.reconnectDelay * Math.pow(2, this.reconnectAttempts - 1)

        setTimeout(() => {
            logDebug(`Reconnecting to relay (attempt ${this.reconnectAttempts})`)
            this.connect().catch(() => {
                // Will retry on close
            })
        }, delay)
    }
}

export function createRelayClient(options: RelayClientOptions): RelayClient {
    if (!options.enabled || !options.url) {
        return new NoopRelayClient()
    }

    return new WebSocketRelayClient(options)
}
