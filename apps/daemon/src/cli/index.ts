#!/usr/bin/env node
/**
 * hud-claude - CLI entry point for HUD daemon
 * Spawns Claude with stream-json and tracks state for HUD
 *
 * Usage:
 *   hud-claude [prompt]           - Start interactive session
 *   hud-claude -p "prompt"        - Run single prompt
 *   hud-claude --resume <id>      - Resume session
 */

import { createInterface } from 'node:readline'
import {
    query,
    type SDKUserMessage,
    isSDKSystemMessage,
    isSDKResultMessage,
    logDebug,
    PushableAsyncIterable
} from '../sdk/index.js'
import { StateTracker } from '../daemon/state.js'
import { formatMessage } from './formatter.js'

interface CliOptions {
    prompt?: string
    resume?: string
    model?: string
    print?: boolean
}

function parseArgs(args: string[]): CliOptions {
    const options: CliOptions = {}

    for (let i = 0; i < args.length; i++) {
        const arg = args[i]

        if (arg === '-p' || arg === '--print') {
            options.print = true
            if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
                options.prompt = args[++i]
            }
        } else if (arg === '--resume' || arg === '-r') {
            if (i + 1 < args.length) {
                options.resume = args[++i]
            }
        } else if (arg === '--model' || arg === '-m') {
            if (i + 1 < args.length) {
                options.model = args[++i]
            }
        } else if (arg === '--help' || arg === '-h') {
            printHelp()
            process.exit(0)
        } else if (!arg.startsWith('-') && !options.prompt) {
            options.prompt = arg
        }
    }

    return options
}

function printHelp(): void {
    console.log(`
hud-claude - Claude Code with HUD state tracking

Usage:
  hud-claude [options] [prompt]

Options:
  -p, --print <prompt>   Run a single prompt (non-interactive)
  -r, --resume <id>      Resume a previous session
  -m, --model <model>    Specify model (sonnet, opus, haiku)
  -h, --help             Show this help message

Examples:
  hud-claude                          # Start interactive session
  hud-claude "explain this code"      # Quick prompt
  hud-claude -p "fix the bug"         # Non-interactive prompt
  hud-claude --resume abc-123         # Resume session

The daemon tracks Claude's state and writes to ~/.claude/hud-session-states.json
for the Swift HUD to read.
`)
}

async function runSinglePrompt(prompt: string, options: CliOptions): Promise<void> {
    const cwd = process.cwd()
    const stateTracker = new StateTracker(cwd)

    stateTracker.handleQueryStart()

    const queryInstance = query({
        prompt,
        options: {
            cwd,
            resume: options.resume,
            model: options.model
        }
    })

    try {
        for await (const message of queryInstance) {
            if (isSDKSystemMessage(message)) {
                stateTracker.handleSessionInit(message)
            }

            formatMessage(message)

            if (isSDKResultMessage(message)) {
                stateTracker.handleResult(message)
            }
        }
    } catch (error) {
        if (error instanceof Error && error.name === 'AbortError') {
            console.log('\nAborted.')
        } else {
            console.error('Error:', error)
            process.exit(1)
        }
    } finally {
        stateTracker.setIdle()
    }
}

async function runInteractive(options: CliOptions): Promise<void> {
    const cwd = process.cwd()
    const stateTracker = new StateTracker(cwd)

    const messages = new PushableAsyncIterable<SDKUserMessage>()

    const rl = createInterface({
        input: process.stdin,
        output: process.stdout
    })

    const prompt = (): Promise<string | null> => {
        return new Promise((resolve) => {
            rl.question('\n> ', (answer) => {
                if (answer === null || answer === undefined) {
                    resolve(null)
                } else {
                    resolve(answer.trim())
                }
            })
        })
    }

    console.log('Claude Code (with HUD tracking)')
    console.log('Type your message and press Enter. Ctrl+C to exit.\n')

    const firstPrompt = options.prompt || await prompt()
    if (!firstPrompt) {
        rl.close()
        return
    }

    messages.push({
        type: 'user',
        message: { role: 'user', content: firstPrompt }
    })

    stateTracker.handleQueryStart()

    const queryInstance = query({
        prompt: messages,
        options: {
            cwd,
            resume: options.resume,
            model: options.model
        }
    })

    const handleMessages = async () => {
        try {
            for await (const message of queryInstance) {
                if (isSDKSystemMessage(message)) {
                    stateTracker.handleSessionInit(message)
                    logDebug(`Session: ${message.session_id}`)
                }

                formatMessage(message)

                if (isSDKResultMessage(message)) {
                    stateTracker.handleResult(message)

                    const nextPrompt = await prompt()
                    if (!nextPrompt) {
                        messages.end()
                        break
                    }

                    stateTracker.handleQueryStart()
                    messages.push({
                        type: 'user',
                        message: { role: 'user', content: nextPrompt }
                    })
                }
            }
        } catch (error) {
            if (error instanceof Error && error.name === 'AbortError') {
                console.log('\nAborted.')
            } else {
                console.error('Error:', error)
            }
        } finally {
            stateTracker.setIdle()
            rl.close()
        }
    }

    process.on('SIGINT', () => {
        console.log('\nInterrupted.')
        messages.end()
        stateTracker.setIdle()
        rl.close()
        process.exit(0)
    })

    await handleMessages()
}

async function main(): Promise<void> {
    const args = process.argv.slice(2)
    const options = parseArgs(args)

    if (options.print && options.prompt) {
        await runSinglePrompt(options.prompt, options)
    } else {
        await runInteractive(options)
    }
}

main().catch((error) => {
    console.error('Fatal error:', error)
    process.exit(1)
})
