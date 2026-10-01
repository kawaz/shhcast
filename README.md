# shhcast

> English | [日本語](./README-ja.md)

A living-room lamp tells your family when you are in a meeting and whether your microphone is on. **Design stage:** the daemon, browser extension, and lamp firmware are not implemented yet.

## Install

Not available yet. This repository currently contains design documents and Swift research probes.

## Usage

The planned lamp states are `idle` (off), `live` (red: in a meeting, microphone on), and `muted` (green: in a meeting, microphone off). Planned sources are Slack huddles and browser-based Google Meet, Teams, and Zoom.

## Documentation

- [Design](./docs/DESIGN.md) — Swift daemon, Chrome extension, and ESP32 lamp
- [Open questions](./docs/QUESTIONS.md)
- [Structure](./docs/STRUCTURE.md)
- [Research findings](./docs/findings/2026-09-30-slack-huddle-ax-and-coreaudio.md)

## License

MIT License, Yoshiaki Kawazu (@kawaz)
