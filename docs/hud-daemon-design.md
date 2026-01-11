# HUD Daemon Design Document

## Overview

The HUD Daemon is a service that spawns Claude Code with `--output-format stream-json`, parses the structured message stream, tracks state, and relays to remote clients. This design is modeled after Happy's battle-tested implementation.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HUD DAEMON                                     │
│                                                                             │
│  ┌─────────────┐    ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │   Terminal  │◀──▶│  I/O Proxy      │◀──▶│  Claude Process             │ │
│  │   (User)    │    │  (stdin/stdout) │    │  --output-format stream-json│ │
│  └─────────────┘    └────────┬────────┘    └──────────────┬──────────────┘ │
│                              │                            │                 │
│                              │  ┌─────────────────────────┘                 │
│                              │  │                                           │
│                              ▼  ▼                                           │
│                     ┌────────────────────┐                                  │
│                     │  Message Parser    │                                  │
│                     │  (JSON readline)   │                                  │
│                     └─────────┬──────────┘                                  │
│                               │                                             │
│              ┌────────────────┼────────────────┐                            │
│              ▼                ▼                ▼                            │
│     ┌────────────────┐ ┌────────────┐ ┌────────────────┐                   │
│     │ State Tracker  │ │ Control    │ │ Relay Client   │                   │
│     │ (thinking,     │ │ Requests   │ │ (WebSocket/    │                   │
│     │  session, etc) │ │ (tools)    │ │  HTTP push)    │                   │
│     └────────────────┘ └────────────┘ └───────┬────────┘                   │
│                                               │                             │
└───────────────────────────────────────────────┼─────────────────────────────┘
                                                │
                                                ▼
                                    ┌─────────────────────┐
                                    │    Relay Server     │
                                    │  (cloud or local)   │
                                    └──────────┬──────────┘
                                               │
                          ┌────────────────────┼────────────────────┐
                          ▼                    ▼                    ▼
                   ┌────────────┐      ┌────────────┐      ┌────────────┐
                   │ Swift HUD  │      │ Mobile App │      │ Web Client │
                   │ (local)    │      │ (iOS)      │      │            │
                   └────────────┘      └────────────┘      └────────────┘
```

## Message Types (from Claude Code)

Based on Happy's SDK types, these are the structured messages we'll receive:

### System Message (subtype: 'init')
```typescript
interface SDKSystemMessage {
    type: 'system'
    subtype: 'init'
    session_id: string
    model: string
    cwd: string
    tools: string[]
    slash_commands: string[]
}
```

### User Message
```typescript
interface SDKUserMessage {
    type: 'user'
    message: {
        role: 'user'
        content: string | ContentBlock[]
    }
}
```

### Assistant Message
```typescript
interface SDKAssistantMessage {
    type: 'assistant'
    message: {
        role: 'assistant'
        content: ContentBlock[]  // text blocks, tool_use blocks
    }
}
```

### Result Message
```typescript
interface SDKResultMessage {
    type: 'result'
    subtype: 'success' | 'error_max_turns' | 'error_during_execution'
    result?: string
    num_turns: number
    usage: {
        input_tokens: number
        output_tokens: number
        cache_read_input_tokens?: number
        cache_creation_input_tokens?: number
    }
    total_cost_usd: number
    duration_ms: number
    session_id: string
}
```

## State Tracking Logic

Following Happy's pattern from `claudeRemote.ts`:

```typescript
// State transitions based on message types
let thinking = false

function updateThinking(newThinking: boolean) {
    if (thinking !== newThinking) {
        thinking = newThinking
        // Push to relay
        relay.pushState({ thinking, timestamp: Date.now() })
    }
}

// Message handling
for await (const message of claudeStream) {
    switch (message.type) {
        case 'system':
            if (message.subtype === 'init') {
                updateThinking(true)  // Session started, Claude is processing
                state.sessionId = message.session_id
                state.model = message.model
            }
            break

        case 'assistant':
            // Still thinking while generating response
            // Could optionally stream content here
            break

        case 'result':
            updateThinking(false)  // Done processing
            state.lastResult = message
            break
    }

    // Forward all messages to relay for remote clients
    relay.pushMessage(message)
}
```

## Core Components

### 1. Claude Process Manager

Spawns Claude with the right flags:

```typescript
const args = [
    '--output-format', 'stream-json',  // Structured JSON output
    '--verbose',                        // Include debug info
    '--input-format', 'stream-json',   // Accept streaming input
]

const claude = spawn('claude', args, {
    cwd: projectPath,
    stdio: ['pipe', 'pipe', 'pipe'],  // stdin, stdout, stderr all piped
    env: getCleanEnv()  // Remove local node_modules from PATH
})
```

### 2. Message Stream Parser

Uses readline to parse JSON lines from stdout:

```typescript
import { createInterface } from 'node:readline'

const rl = createInterface({ input: claude.stdout })

for await (const line of rl) {
    if (line.trim()) {
        const message = JSON.parse(line) as SDKMessage

        // Handle control messages (tool permissions)
        if (message.type === 'control_request') {
            await handleControlRequest(message)
            continue
        }

        // Process SDK messages
        messageStream.enqueue(message)
    }
}
```

### 3. I/O Proxy (for interactive use)

For terminal users, we need to proxy stdin/stdout while also parsing the stream:

```
User Terminal ◀─────▶ HUD Daemon ◀─────▶ Claude Process
    │                     │                    │
    │   stdin (user)      │                    │
    ├────────────────────▶├───────────────────▶│
    │                     │                    │
    │   stdout (claude)   │  (also parsed)     │
    │◀────────────────────┤◀───────────────────┤
    │                     │        │           │
    │                     │        ▼           │
    │                     │   State Tracker    │
    │                     │        │           │
    │                     │        ▼           │
    │                     │   Relay Push       │
```

### 4. Pushable Input Stream

For multi-turn conversations (Happy's pattern):

```typescript
class PushableAsyncIterable<T> implements AsyncIterableIterator<T> {
    private queue: T[] = []
    private waiters: Array<{resolve, reject}> = []
    private isDone = false

    push(value: T): void {
        const waiter = this.waiters.shift()
        if (waiter) {
            waiter.resolve({ done: false, value })
        } else {
            this.queue.push(value)
        }
    }

    end(): void {
        this.isDone = true
        // Resolve all waiters with done
    }

    async next(): Promise<IteratorResult<T>> {
        if (this.queue.length > 0) {
            return { done: false, value: this.queue.shift()! }
        }
        if (this.isDone) {
            return { done: true, value: undefined }
        }
        // Wait for next push
        return new Promise((resolve, reject) => {
            this.waiters.push({ resolve, reject })
        })
    }
}
```

### 5. Control Request Handler

For tool permission prompts (Happy's pattern):

```typescript
async function handleControlRequest(request: CanUseToolControlRequest) {
    const { tool_name, input } = request.request

    // Check against permission policy
    const result = await checkToolPermission(tool_name, input)

    // Send response back to Claude via stdin
    const response: CanUseToolControlResponse = {
        type: 'control_response',
        response: {
            subtype: 'success',
            request_id: request.request_id,
            response: result
        }
    }

    claude.stdin.write(JSON.stringify(response) + '\n')
}
```

## Relay Integration

The daemon pushes state to the relay server:

```typescript
interface RelayClient {
    // Push state changes
    pushState(state: {
        thinking: boolean
        sessionId?: string
        model?: string
        cwd: string
        timestamp: number
    }): void

    // Push individual messages (for streaming to mobile)
    pushMessage(message: SDKMessage): void

    // Push result summary
    pushResult(result: SDKResultMessage): void
}

class WebSocketRelayClient implements RelayClient {
    private ws: WebSocket

    constructor(relayUrl: string, projectId: string) {
        this.ws = new WebSocket(relayUrl)
        // Auth, reconnection logic, etc.
    }

    pushState(state) {
        this.ws.send(JSON.stringify({
            type: 'state_update',
            projectId: this.projectId,
            ...state
        }))
    }
}
```

## Implementation Plan

### Phase 1: Core SDK (TypeScript)

Create a minimal SDK based on Happy's implementation:

```
hud-daemon/
├── src/
│   ├── sdk/
│   │   ├── types.ts         # Message type definitions
│   │   ├── stream.ts        # Async stream implementation
│   │   ├── query.ts         # Claude process spawning
│   │   └── utils.ts         # Path resolution, env cleaning
│   ├── daemon/
│   │   ├── state.ts         # State tracking logic
│   │   ├── relay.ts         # Relay client
│   │   └── index.ts         # Main daemon entry
│   └── cli/
│       └── hud-claude.ts    # User-facing CLI wrapper
├── package.json
└── tsconfig.json
```

### Phase 2: State Tracking

Implement the state machine:

```typescript
enum SessionState {
    Idle = 'idle',
    Ready = 'ready',
    Working = 'working',
    Compacting = 'compacting'
}

interface ProjectState {
    state: SessionState
    thinking: boolean
    sessionId: string | null
    model: string | null
    workingOn: string | null
    nextStep: string | null
    lastActivity: Date
}
```

### Phase 3: Terminal Proxy

For interactive use, proxy the terminal while parsing:

```typescript
// Spawn Claude
const claude = spawn('claude', args, { stdio: ['pipe', 'pipe', 'pipe'] })

// Proxy stdin from user to Claude
process.stdin.pipe(claude.stdin)

// Parse stdout AND display to user
const rl = createInterface({ input: claude.stdout })
for await (const line of rl) {
    // Display to user
    process.stdout.write(line + '\n')

    // Also parse for state tracking
    if (line.trim()) {
        try {
            const message = JSON.parse(line)
            handleMessage(message)
        } catch {
            // Not JSON, just output
        }
    }
}
```

### Phase 4: Relay Integration

Connect to the relay server:

```typescript
const relay = new WebSocketRelayClient(
    process.env.HUD_RELAY_URL || 'ws://localhost:8080',
    projectId
)

// Push state on every update
stateTracker.on('stateChange', (state) => {
    relay.pushState(state)
})

// Optionally stream messages
messageStream.on('message', (msg) => {
    if (shouldRelayMessage(msg)) {
        relay.pushMessage(msg)
    }
})
```

## CLI Usage

> **Note:** The daemon is separate from normal Claude usage. For interactive TUI with hooks-based state tracking, run `claude` or `hud-claude`. The daemon (`hud-claude-daemon`) is for programmatic use or future mobile relay.

```bash
# Normal Claude TUI with hooks (recommended for local development)
$ claude
# or
$ hud-claude  # Wrapper that runs regular Claude

# Daemon mode (JSON output, no TUI) - for programmatic/remote use
$ hud-claude-daemon

# Or with arguments
$ hud-claude-daemon --resume abc-123
$ hud-claude-daemon -p "explain this code"

# The daemon handles:
# 1. Spawning Claude with --output-format stream-json
# 2. Parsing message stream
# 3. Tracking state precisely
# 4. Writing to state file
# 5. (Future) Pushing to relay
```

## Comparison with Current Hooks Approach

| Aspect | Hooks (Current Local) | Daemon (Future Remote) |
|--------|----------------------|------------------------|
| State Granularity | Event-based (hook events) | Message-level (streaming) |
| Thinking Accuracy | Very good (~100ms) | Precise (from message types) |
| Remote Latency | File → Publish → Relay | Direct stream → Relay |
| User Experience | ✅ Transparent, keeps TUI | ❌ Replaces TUI with JSON |
| Implementation | Shell scripts | TypeScript daemon |
| Content Streaming | Not possible | Can stream response text |
| Session Management | Via hooks | Full control |
| Use Case | Local desktop development | Mobile/remote clients |

## Current Architecture Decision

See [ADR-001: State Tracking Approach](architecture-decisions/001-state-tracking-approach.md).

**Summary:** We use hooks for local TUI sessions (preserves Claude's interactive experience). The daemon is reserved for future mobile/remote client integration where TUI isn't needed.

## Migration Path (Future)

1. **Current:** Hooks for local use - Swift HUD reads state file
2. **Future:** Daemon for remote use - Mobile connects via relay
3. **Optional:** Mode-switching (like Happy) if seamless local/remote is needed

## Security Considerations

1. **Process Isolation** - Daemon runs with user privileges
2. **Relay Auth** - WebSocket connections must be authenticated
3. **Input Validation** - Never trust relay commands without validation
4. **Permission Passthrough** - Tool permissions still go through Claude's system

## Open Questions

1. **Terminal Emulation** - For full interactive support, may need PTY handling
2. **Multiple Projects** - One daemon per project, or single daemon managing all?
3. **Daemon Lifecycle** - How to start/stop/restart the daemon?
4. **Local State File** - Should daemon also write to local state file for Swift HUD?

## References

- Happy's SDK implementation: `/Users/petepetrash/Code/happy-cli/src/claude/sdk/`
- Happy's remote mode: `/Users/petepetrash/Code/happy-cli/src/claude/claudeRemote.ts`
- Claude Code `--output-format stream-json` documentation
