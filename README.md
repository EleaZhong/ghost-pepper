# Ghost Pepper (personal instrument)

Personal voice dictation for macOS, stripped to the core: hold a key, talk, get text
pasted where your cursor is. 100% on-device.

Forked from [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper)
(MIT). This is a pure personal mod: the meetings, second-brain/wiki, QA, chat, and
cloud-integration subsystems were removed; what remains is the dictation core plus
the transcription lab.

## What it does

- **Hold Control to talk** — release to transcribe and paste into any text field
- **Local speech models** via WhisperKit / FluidAudio / MLX — nothing leaves the machine
- **Cleanup pass** — a local LLM removes fillers and resolves self-corrections
- **Vocabulary glossary** — your terms feed decoding (promptTokens), cleanup hints, and OCR
- **Transcription lab** — an append-only archive of every dictation (audio + text + timings);
  the raw material for evaluating models against your own voice

## Presets, not knobs

Configuration ships as baked presets born from measurement (see the voice-eval harness);
the only switches are the preset, the microphone, and the voice tag.

## Build

Open `GhostPepper.xcodeproj` and build (Cmd+R). Needs `Config/LocalSigning.xcconfig`
with your `DEVELOPMENT_TEAM` (see the example file).
