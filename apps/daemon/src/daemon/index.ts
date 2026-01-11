/**
 * HUD Daemon - orchestrates Claude Code spawning, state tracking, and relay
 */

import {
    query,
    type SDKMessage,
    type SDKUserMessage,
    isSDKSystemMessage,
    isSDKResultMessage,
    logDebug,
    PushableAsyncIterable
} from '../sdk/index.js'
import { StateTracker } from './state.js'
import { createRelayClient, type RelayClient, type RelayClientOptions } from './relay.js'

export interface DaemonOptions {
    cwd: string
    resume?: string
    model?: string
    relay?: RelayClientOptions
    onMessage?: (message: SDKMessage) => void
    onThinkingChange?: (thinking: boolean) => void
    onReady?: () => void
}

export interface DaemonSession {
    sendMessage(content: string): void
    interrupt(): Promise<void>
    end(): void
    getThinking(): boolean
    getSessionId(): string | null
}

export async function createDaemonSession(
    initialPrompt: string,
    options: DaemonOptions
): Promise<DaemonSession> {
    const { cwd, resume, model, relay: relayOptions, onMessage, onThinkingChange, onReady } = options

    const relayClient: RelayClient = createRelayClient(relayOptions || {})

    const stateTracker = new StateTracker(cwd, {
        onThinkingChange: (thinking) => {
            onThinkingChange?.(thinking)
            relayClient.pushState({
                cwd,
                thinking,
                state: stateTracker.getState(),
                sessionId: stateTracker.getSessionId(),
                model: model || null,
                timestamp: Date.now()
            })
        },
        onStateChange: (state) => {
            relayClient.pushState({
                cwd,
                thinking: stateTracker.getThinking(),
                state,
                sessionId: stateTracker.getSessionId(),
                model: model || null,
                timestamp: Date.now()
            })
        },
        onResult: (result) => {
            relayClient.pushResult(result)
        }
    })

    const messages = new PushableAsyncIterable<SDKUserMessage>()

    messages.push({
        type: 'user',
        message: {
            role: 'user',
            content: initialPrompt
        }
    })

    stateTracker.handleQueryStart()

    const queryInstance = query({
        prompt: messages,
        options: {
            cwd,
            resume,
            model
        }
    })

    const processMessages = async () => {
        try {
            for await (const message of queryInstance) {
                logDebug(`Message: ${message.type}`)
                onMessage?.(message)
                relayClient.pushMessage(message)

                if (isSDKSystemMessage(message)) {
                    stateTracker.handleSessionInit(message)
                }

                if (isSDKResultMessage(message)) {
                    stateTracker.handleResult(message)
                    onReady?.()
                }
            }
        } catch (error) {
            if (error instanceof Error && error.name === 'AbortError') {
                logDebug('Session aborted')
            } else {
                logDebug(`Session error: ${error}`)
            }
        } finally {
            stateTracker.setIdle()
        }
    }

    processMessages()

    return {
        sendMessage(content: string): void {
            stateTracker.handleQueryStart()
            messages.push({
                type: 'user',
                message: {
                    role: 'user',
                    content
                }
            })
        },

        async interrupt(): Promise<void> {
            await queryInstance.interrupt()
        },

        end(): void {
            messages.end()
        },

        getThinking(): boolean {
            return stateTracker.getThinking()
        },

        getSessionId(): string | null {
            return stateTracker.getSessionId()
        }
    }
}

export { StateTracker } from './state.js'
export { createRelayClient, type RelayClient, type RelayClientOptions, type RelayState } from './relay.js'
