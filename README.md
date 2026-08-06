# Claude Stats

A macOS menu bar app showing Claude Code usage stats parsed from `~/.claude` JSONL transcripts.

## Build

```sh
swift build
swift test
```

## Run (menu bar app)

```sh
bash scripts/bundle.sh
open .build/ClaudeStats.app
```

## Dev CLI

```sh
swift run ClaudeStatsCLI --summary
```
