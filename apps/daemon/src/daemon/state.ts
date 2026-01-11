/**
 * State tracker - tracks Claude session state and writes to state file
 * Compatible with the existing hud-session-states.json format used by Swift HUD
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { getStateFilePath, getClaudeDir, ensureDir, logDebug } from '../sdk/utils.js'
import type { SDKSystemMessage, SDKResultMessage } from '../sdk/types.js'

export type SessionState = 'idle' | 'ready' | 'working' | 'compacting'

export interface ProjectState {
    state: SessionState
    state_changed_at: string
    session_id: string | null
    working_on: string | null
    next_step: string | null
    thinking: boolean
    thinking_updated_at: string
    context?: {
        updated_at: string
    }
}

export interface StateFile {
    version: number
    projects: Record<string, ProjectState>
}

export interface StateTrackerEvents {
    onThinkingChange?: (thinking: boolean) => void
    onStateChange?: (state: SessionState) => void
    onSessionStart?: (sessionId: string, model: string) => void
    onResult?: (result: SDKResultMessage) => void
}

export class StateTracker {
    private cwd: string
    private thinking = false
    private state: SessionState = 'idle'
    private sessionId: string | null = null
    private model: string | null = null
    private events: StateTrackerEvents

    constructor(cwd: string, events: StateTrackerEvents = {}) {
        this.cwd = cwd
        this.events = events
    }

    getThinking(): boolean {
        return this.thinking
    }

    getState(): SessionState {
        return this.state
    }

    getSessionId(): string | null {
        return this.sessionId
    }

    updateThinking(newThinking: boolean): void {
        if (this.thinking !== newThinking) {
            this.thinking = newThinking
            logDebug(`Thinking state changed to: ${newThinking}`)
            this.events.onThinkingChange?.(newThinking)
            this.writeState()
        }
    }

    updateState(newState: SessionState): void {
        if (this.state !== newState) {
            this.state = newState
            logDebug(`Session state changed to: ${newState}`)
            this.events.onStateChange?.(newState)
            this.writeState()
        }
    }

    handleSessionInit(message: SDKSystemMessage): void {
        this.sessionId = message.session_id
        this.model = message.model
        this.updateState('working')
        this.updateThinking(true)
        logDebug(`Session initialized: ${this.sessionId}, model: ${this.model}`)
        this.events.onSessionStart?.(this.sessionId, this.model)
    }

    handleResult(message: SDKResultMessage): void {
        this.updateThinking(false)
        this.updateState('ready')
        logDebug(`Result received: ${message.subtype}`)
        this.events.onResult?.(message)
    }

    handleQueryStart(): void {
        this.updateState('working')
        this.updateThinking(true)
    }

    private readStateFile(): StateFile {
        const stateFilePath = getStateFilePath()

        if (!existsSync(stateFilePath)) {
            return { version: 1, projects: {} }
        }

        try {
            const content = readFileSync(stateFilePath, 'utf-8')
            return JSON.parse(content) as StateFile
        } catch {
            logDebug('Failed to read state file, creating new one')
            return { version: 1, projects: {} }
        }
    }

    private writeState(): void {
        const stateFilePath = getStateFilePath()
        ensureDir(getClaudeDir())

        const timestamp = new Date().toISOString()
        const stateFile = this.readStateFile()

        const projectState: ProjectState = {
            state: this.state,
            state_changed_at: timestamp,
            session_id: this.sessionId,
            working_on: null,
            next_step: null,
            thinking: this.thinking,
            thinking_updated_at: timestamp,
            context: {
                updated_at: timestamp
            }
        }

        stateFile.projects[this.cwd] = projectState

        try {
            writeFileSync(stateFilePath, JSON.stringify(stateFile, null, 2))
            logDebug(`State written to ${stateFilePath}`)
        } catch (error) {
            logDebug(`Failed to write state file: ${error}`)
        }
    }

    setIdle(): void {
        this.updateThinking(false)
        this.updateState('idle')
        this.sessionId = null
    }
}
