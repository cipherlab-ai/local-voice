# AGENTS.md — Local Voice

Private, system-wide dictation for macOS with a native iPhone companion — a Cipher Lab product built on the MIT-licensed `open-wispr` lineage around a shared local speech core. GitHub `cipherholdingsllc/local-voice`, local checkout `~/Desktop/CipherOS/local-voice` (nested repo inside the CipherOS checkout — treat as its own repo).

## Non-negotiables

1. **Privacy is the product.** Audio and transcripts stay on-device per `NETWORK_ISOLATION.md` — no telemetry, analytics, or network calls get added without explicit approval. Verify network isolation claims before asserting them.
2. **macOS-native work stays local.** Xcode/Swift builds, Simulator runs, TCC/Accessibility state — this repo needs the Mac, not a cloud session (see surface-routing rules).
3. **Two products, one core.** Local Voice (desktop/mobile dictation) and Exploit Poker Voice (domain surface on the shared runtime). Shared engines yes — no overloaded GUI, no silent cross-product data flow.
4. Git safety: no force pushes, no history rewrites, no commits or pushes to `main` without explicit approval. Do not `git add -A`. Never commit `Local Voice.app` build products, model files, secrets, or `.env*`.
5. Doctor skill exists: `.devin/skills/local-voice-doctor/SKILL.md` — use it for fn-hotkey, paste, TCC, or whisper-server issues instead of guessing.

## Context

- `README.md` — product shape and implemented features (read first).
- `STATUS.md`, `PLAN.md`, `BENCHMARK.md`, `MODELS.md` — build state and perf bar.
- `NETWORK_ISOLATION.md` — the privacy contract.
- `Package.swift`, `Sources/`, `Tests/` — SPM layout; `Formula/` — Homebrew cask.
- Operating doctrine: `~/.config/devin/AGENTS.md` and `~/Desktop/CipherOS/AGENTS.md`.
