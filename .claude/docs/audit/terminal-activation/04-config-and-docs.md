# Subsystem 4: Config/Debug + Docs

## Findings

### [Config/Debug] Finding 1: ActivationConfigStore Is Detached From Execution Path

**Severity:** Low
**Type:** Dead code
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:133`, `apps/swift/Sources/Capacitor/Models/ActivationConfig.swift:269-319`

**Problem:**
`TerminalLauncher` holds a `configStore` reference, but the activation path never reads from it. The only active consumer is the debug ShellMatrix UI. This creates two sources of “activation logic” (Rust resolver vs. configurable Swift strategies) with no runtime coupling, which is confusing and hinders refactoring.

**Evidence:**
```
private let configStore = ActivationConfigStore.shared
```
(`TerminalLauncher.swift:133`)

`ActivationConfigStore` persists overrides, but `TerminalLauncher` never consults it.

**Recommendation:**
Either remove `ActivationConfigStore` from runtime activation or integrate it explicitly into the resolver path (preferably in Rust, then re-export). Keeping it only for debug UI without clear separation invites drift.

---

### [Docs] Finding 2: Terminal Switching Matrix Is Stale vs Current Behavior

**Severity:** Low
**Type:** Stale docs
**Location:** `.claude/docs/terminal-switching-matrix.md:126-176`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:709-731`, `core/hud-core/src/activation.rs:101-105`

**Problem:**
The matrix marks IDE activation as broken (❌) and notes “uses first match” for multiple shells, but the current code includes explicit IDE window activation via CLI and a deterministic “most recent shell” resolver in Rust. These mismatches will mislead future refactors and testing.

**Evidence:**
Matrix claims IDE activation fails:
```
| 41 | Integrated terminal | 1 window | "cursor" | Activate Cursor | ❌ | Falls through, activates random terminal |
```
(`terminal-switching-matrix.md:126-131`)

Implementation supports IDE activation:
```
private func activateIDEWindowInternal(app: ParentApp, projectPath: String) -> Bool { ... }
```
(`TerminalLauncher.swift:709-731`)

Rust resolver explicitly returns `ActivateIdeWindow`:
```
ActivateIdeWindow { ide_type, project_path }
```
(`activation.rs:101-105`)

Matrix claims multiple shells uses first match:
```
| 34 | Multiple shells same project | Activate most recent? | ❓ | Uses first match |
```
(`terminal-switching-matrix.md:172-176`)

Rust resolver now selects most recent/live shells.

**Recommendation:**
Update the matrix to reflect current IDE activation paths and the Rust shell-selection logic. Treat it as a regression checklist with verified status for each scenario.
