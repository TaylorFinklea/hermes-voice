"""Coding-agent harness adapters (Claude Code, Codex, OpenCode).

Each class satisfies the HarnessClient protocol (`app/harness.py`) and runs its
CLI in the shared workspace under a workspace-write sandbox. They're registered
by availability in `main.create_app`.
"""
from .claude import ClaudeAdapter
from .codex import CodexAdapter
from .opencode import OpenCodeAdapter

# Harness id → adapter class, in display order. Hermes is registered separately
# in main.create_app (it's the default and predates this package).
ADAPTER_CLASSES = {
    "claude": ClaudeAdapter,
    "codex": CodexAdapter,
    "opencode": OpenCodeAdapter,
}

__all__ = ["ClaudeAdapter", "CodexAdapter", "OpenCodeAdapter", "ADAPTER_CLASSES"]
