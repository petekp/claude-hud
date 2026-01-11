/**
 * Message formatter - formats SDK messages for terminal display
 * Based on Happy's messageFormatter but simplified for HUD daemon
 */

import type {
    SDKMessage,
    SDKSystemMessage,
    SDKUserMessage,
    SDKAssistantMessage,
    SDKResultMessage,
    ContentBlock
} from '../sdk/types.js'

const COLORS = {
    reset: '\x1b[0m',
    bold: '\x1b[1m',
    dim: '\x1b[2m',
    cyan: '\x1b[36m',
    green: '\x1b[32m',
    yellow: '\x1b[33m',
    magenta: '\x1b[35m',
    red: '\x1b[31m',
    gray: '\x1b[90m'
}

function color(text: string, ...codes: string[]): string {
    return `${codes.join('')}${text}${COLORS.reset}`
}

export function formatMessage(message: SDKMessage): void {
    switch (message.type) {
        case 'system':
            formatSystemMessage(message as SDKSystemMessage)
            break
        case 'user':
            formatUserMessage(message as SDKUserMessage)
            break
        case 'assistant':
            formatAssistantMessage(message as SDKAssistantMessage)
            break
        case 'result':
            formatResultMessage(message as SDKResultMessage)
            break
        case 'log':
            // Skip log messages in normal output
            break
        default:
            // Unknown message type - skip
            break
    }
}

function formatSystemMessage(message: SDKSystemMessage): void {
    if (message.subtype === 'init') {
        console.log(color('─'.repeat(60), COLORS.gray))
        console.log(color('Session initialized', COLORS.cyan, COLORS.bold))
        console.log(color(`  Model: ${message.model}`, COLORS.gray))
        console.log(color(`  CWD: ${message.cwd}`, COLORS.gray))
        if (message.tools?.length) {
            console.log(color(`  Tools: ${message.tools.length} available`, COLORS.gray))
        }
        console.log(color('─'.repeat(60), COLORS.gray))
    }
}

function formatUserMessage(message: SDKUserMessage): void {
    const content = message.message.content

    if (typeof content === 'string') {
        console.log(color('\n👤 You: ', COLORS.magenta, COLORS.bold) + content)
    } else if (Array.isArray(content)) {
        for (const block of content) {
            if (block.type === 'text' && block.text) {
                console.log(color('\n👤 You: ', COLORS.magenta, COLORS.bold) + block.text)
            } else if (block.type === 'tool_result') {
                console.log(color('\n✅ Tool Result', COLORS.green, COLORS.bold))
                if (block.content) {
                    const output = typeof block.content === 'string'
                        ? block.content
                        : JSON.stringify(block.content, null, 2)
                    const truncated = output.length > 200
                        ? output.substring(0, 200) + color('\n... (truncated)', COLORS.gray)
                        : output
                    console.log(truncated)
                }
            }
        }
    }
}

function formatAssistantMessage(message: SDKAssistantMessage): void {
    if (!message.message?.content) return

    for (const block of message.message.content) {
        formatContentBlock(block)
    }
}

function formatContentBlock(block: ContentBlock): void {
    if (block.type === 'text' && block.text) {
        console.log(color('\n🤖 Claude: ', COLORS.cyan, COLORS.bold))
        console.log(block.text)
    } else if (block.type === 'tool_use') {
        console.log(color(`\n🔧 Tool: ${block.name}`, COLORS.yellow, COLORS.bold))
        if (block.input) {
            const inputStr = JSON.stringify(block.input, null, 2)
            const truncated = inputStr.length > 500
                ? inputStr.substring(0, 500) + color('\n... (truncated)', COLORS.gray)
                : inputStr
            console.log(color('Input: ', COLORS.gray) + truncated)
        }
    }
}

function formatResultMessage(message: SDKResultMessage): void {
    console.log()

    if (message.subtype === 'success') {
        if (message.result) {
            console.log(color('✨ Summary:', COLORS.green, COLORS.bold))
            console.log(message.result)
        }

        if (message.usage) {
            console.log(color('\n📊 Stats:', COLORS.gray))
            console.log(color(`  Turns: ${message.num_turns}`, COLORS.gray))
            console.log(color(`  Input tokens: ${message.usage.input_tokens}`, COLORS.gray))
            console.log(color(`  Output tokens: ${message.usage.output_tokens}`, COLORS.gray))
            if (message.usage.cache_read_input_tokens) {
                console.log(color(`  Cache read: ${message.usage.cache_read_input_tokens}`, COLORS.gray))
            }
            console.log(color(`  Cost: $${message.total_cost_usd.toFixed(4)}`, COLORS.gray))
            console.log(color(`  Duration: ${message.duration_ms}ms`, COLORS.gray))
        }
    } else if (message.subtype === 'error_max_turns') {
        console.log(color('❌ Maximum turns reached', COLORS.red, COLORS.bold))
        console.log(color(`Completed ${message.num_turns} turns`, COLORS.gray))
    } else if (message.subtype === 'error_during_execution') {
        console.log(color('❌ Error during execution', COLORS.red, COLORS.bold))
        console.log(color(`Completed ${message.num_turns} turns before error`, COLORS.gray))
    }
}
