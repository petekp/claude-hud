/**
 * HUD Daemon SDK - Claude Code integration
 */

export { query, Query, type QueryConfig } from './query.js'
export { Stream } from './stream.js'
export { PushableAsyncIterable } from './pushable.js'
export {
    type SDKMessage,
    type SDKUserMessage,
    type SDKAssistantMessage,
    type SDKSystemMessage,
    type SDKResultMessage,
    type SDKLogMessage,
    type SDKControlResponse,
    type ContentBlock,
    type QueryOptions,
    type QueryPrompt,
    type PermissionResult,
    type CanCallToolCallback,
    AbortError,
    isSDKSystemMessage,
    isSDKResultMessage,
    isSDKAssistantMessage,
    isSDKUserMessage
} from './types.js'
export {
    getDefaultClaudeCodePath,
    getCleanEnv,
    getStateFilePath,
    getClaudeDir,
    ensureDir,
    logDebug
} from './utils.js'
