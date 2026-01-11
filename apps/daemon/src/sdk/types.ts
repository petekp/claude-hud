/**
 * Type definitions for Claude Code SDK integration
 * Based on Happy's battle-tested implementation
 */

export interface SDKMessage {
    type: string
    [key: string]: unknown
}

export interface SDKUserMessage extends SDKMessage {
    type: 'user'
    parent_tool_use_id?: string
    message: {
        role: 'user'
        content: string | ContentBlock[]
    }
}

export interface SDKAssistantMessage extends SDKMessage {
    type: 'assistant'
    parent_tool_use_id?: string
    message: {
        role: 'assistant'
        content: ContentBlock[]
    }
}

export interface SDKSystemMessage extends SDKMessage {
    type: 'system'
    subtype: 'init'
    session_id: string
    model: string
    cwd: string
    tools: string[]
    slash_commands?: string[]
}

export interface SDKResultMessage extends SDKMessage {
    type: 'result'
    subtype: 'success' | 'error_max_turns' | 'error_during_execution'
    result?: string
    num_turns: number
    usage?: {
        input_tokens: number
        output_tokens: number
        cache_read_input_tokens?: number
        cache_creation_input_tokens?: number
    }
    total_cost_usd: number
    duration_ms: number
    duration_api_ms?: number
    is_error: boolean
    session_id: string
}

export interface SDKLogMessage extends SDKMessage {
    type: 'log'
    log: {
        level: 'debug' | 'info' | 'warn' | 'error'
        message: string
    }
}

export interface ContentBlock {
    type: string
    text?: string
    id?: string
    name?: string
    input?: unknown
    tool_use_id?: string
    content?: unknown
    [key: string]: unknown
}

export interface SDKControlResponse extends SDKMessage {
    type: 'control_response'
    response: {
        request_id: string
        subtype: 'success' | 'error'
        error?: string
        response?: PermissionResult
    }
}

export interface ControlRequest {
    subtype: string
}

export interface CanUseToolRequest extends ControlRequest {
    subtype: 'can_use_tool'
    tool_name: string
    input: unknown
}

export interface CanUseToolControlRequest {
    type: 'control_request'
    request_id: string
    request: CanUseToolRequest
}

export interface CanUseToolControlResponse {
    type: 'control_response'
    response: {
        subtype: 'success' | 'error'
        request_id: string
        response?: PermissionResult
        error?: string
    }
}

export interface ControlCancelRequest {
    type: 'control_cancel_request'
    request_id: string
}

export interface SDKControlRequest {
    request_id: string
    type: 'control_request'
    request: ControlRequest
}

export interface InterruptRequest extends ControlRequest {
    subtype: 'interrupt'
}

export type PermissionResult = {
    behavior: 'allow'
    updatedInput?: Record<string, unknown>
} | {
    behavior: 'deny'
    message: string
}

export interface CanCallToolCallback {
    (toolName: string, input: unknown, options: { signal: AbortSignal }): Promise<PermissionResult>
}

export interface QueryOptions {
    abort?: AbortSignal
    allowedTools?: string[]
    appendSystemPrompt?: string
    customSystemPrompt?: string
    cwd?: string
    disallowedTools?: string[]
    maxTurns?: number
    mcpServers?: Record<string, unknown>
    pathToClaudeCodeExecutable?: string
    permissionMode?: 'default' | 'acceptEdits' | 'bypassPermissions' | 'plan'
    continue?: boolean
    resume?: string
    model?: string
    fallbackModel?: string
    canCallTool?: CanCallToolCallback
    settingsPath?: string
}

export type QueryPrompt = string | AsyncIterable<SDKMessage>

export type ControlResponseHandler = (response: SDKControlResponse['response']) => void

export class AbortError extends Error {
    constructor(message: string) {
        super(message)
        this.name = 'AbortError'
    }
}

export function isSDKSystemMessage(msg: SDKMessage): msg is SDKSystemMessage {
    return msg.type === 'system' && (msg as SDKSystemMessage).subtype === 'init'
}

export function isSDKResultMessage(msg: SDKMessage): msg is SDKResultMessage {
    return msg.type === 'result'
}

export function isSDKAssistantMessage(msg: SDKMessage): msg is SDKAssistantMessage {
    return msg.type === 'assistant'
}

export function isSDKUserMessage(msg: SDKMessage): msg is SDKUserMessage {
    return msg.type === 'user'
}
