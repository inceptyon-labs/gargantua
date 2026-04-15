# Session Handoff: Build Process-based Mole runner
Date: 2026-04-15
Task: gargantua-t6wk — Build Process-based Mole runner with timeout and isolation
Parent: gargantua-rsnu — Feature: Mole Subprocess Wrapper

## What Was Done
- Completed Task: gargantua-t6wk — MoleRunner subprocess wrapper
- MoleRunner: Process-based execution with configurable timeout, crash detection, binary path resolution
- 19 new tests covering config, result model, errors, real process, and timeout behavior

## Files Changed
- Sources/GargantuaCore/Services/MoleRunner.swift (new)
- Tests/GargantuaCoreTests/Services/MoleRunnerTests.swift (new)

## Key Decisions
- Process.terminate() on timeout for immediate subprocess cleanup
- Crash detection via exitCode > 128 (Unix signal convention)
- Binary path resolution: explicit config > Bundle.main.resourceURL > Contents/Resources
- Environment inherited from parent for TCC propagation

## Next Steps (ordered)
1. gargantua-obof — Parse Mole JSON output into ScanResult models (remaining task under gargantua-rsnu)
2. Continue with other backend tasks

## Files to Load Next Session
- Sources/GargantuaCore/Services/MoleRunner.swift
- Sources/GargantuaCore/Models/ScanResult.swift
- Sources/GargantuaCore/Models/SafetyLevel.swift

## What NOT to Re-Read
- Models/AuditEntry.swift, Models/AlertItem.swift, Models/CleanupProfile.swift — unchanged
- Views/ — not relevant to Mole integration
- Parsing/ — not relevant
