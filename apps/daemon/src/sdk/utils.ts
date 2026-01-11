/**
 * Utility functions for Claude Code SDK integration
 * Based on Happy's utils with adaptations for HUD
 */

import { execSync } from 'node:child_process'
import { existsSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { Writable } from 'node:stream'

const DEBUG = process.env.DEBUG === '1' || process.env.DEBUG === 'true'

export function logDebug(message: string): void {
    if (DEBUG) {
        console.error(`[hud-daemon] ${message}`)
    }
}

export function getCleanEnv(): NodeJS.ProcessEnv {
    const env = { ...process.env }
    const cwd = process.cwd()
    const pathSep = process.platform === 'win32' ? ';' : ':'
    const pathKey = process.platform === 'win32' ? 'Path' : 'PATH'

    const actualPathKey = Object.keys(env).find(k => k.toLowerCase() === 'path') || pathKey

    if (env[actualPathKey]) {
        const cleanPath = env[actualPathKey]!
            .split(pathSep)
            .filter(p => {
                const normalizedP = p.replace(/\\/g, '/').toLowerCase()
                const normalizedCwd = cwd.replace(/\\/g, '/').toLowerCase()
                return !normalizedP.startsWith(normalizedCwd)
            })
            .join(pathSep)
        env[actualPathKey] = cleanPath
        logDebug(`Cleaned PATH, removed local paths from: ${cwd}`)
    }

    return env
}

function findGlobalClaudePath(): string | null {
    const homeDir = homedir()
    const cleanEnv = getCleanEnv()

    try {
        execSync('claude --version', {
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'pipe'],
            cwd: homeDir,
            env: cleanEnv
        })
        logDebug('Global claude command available')
        return 'claude'
    } catch {
        // Not available globally
    }

    if (process.platform !== 'win32') {
        try {
            const result = execSync('which claude', {
                encoding: 'utf8',
                stdio: ['pipe', 'pipe', 'pipe'],
                cwd: homeDir,
                env: cleanEnv
            }).trim()
            if (result && existsSync(result)) {
                logDebug(`Found global claude via which: ${result}`)
                return result
            }
        } catch {
            // which didn't find it
        }
    }

    const commonPaths = [
        '/opt/homebrew/bin/claude',
        '/usr/local/bin/claude',
        join(homeDir, '.npm-global/bin/claude'),
        join(homeDir, '.local/bin/claude'),
    ]

    for (const p of commonPaths) {
        if (existsSync(p)) {
            logDebug(`Found claude at common path: ${p}`)
            return p
        }
    }

    return null
}

export function getDefaultClaudeCodePath(): string {
    if (process.env.HUD_CLAUDE_PATH) {
        logDebug(`Using HUD_CLAUDE_PATH: ${process.env.HUD_CLAUDE_PATH}`)
        return process.env.HUD_CLAUDE_PATH
    }

    const globalPath = findGlobalClaudePath()

    if (!globalPath) {
        throw new Error(
            'Could not find claude CLI. Please ensure @anthropic-ai/claude-code is installed globally.'
        )
    }

    return globalPath
}

export async function streamToStdin(
    stream: AsyncIterable<unknown>,
    stdin: Writable,
    abort?: AbortSignal
): Promise<void> {
    try {
        for await (const message of stream) {
            if (abort?.aborted) break
            stdin.write(JSON.stringify(message) + '\n')
        }
    } finally {
        stdin.end()
    }
}

export function getStateFilePath(): string {
    return join(homedir(), '.claude', 'hud-session-states.json')
}

export function getClaudeDir(): string {
    return join(homedir(), '.claude')
}

export function ensureDir(dir: string): void {
    if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true })
    }
}
