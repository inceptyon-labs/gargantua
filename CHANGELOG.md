# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Added Mole-backed app cleanup coverage for cloud-sync, Office/mail, communication, virtualization, creative/media, productivity, launcher, game, utility, and remote desktop caches.
- Expanded Smart Uninstaller remnant rules with Mole-backed WebKit, HTTP storage, app script, plug-in, XDG config, app extension, system-level, and protected receipt templates.
- Synced the reviewed Mole-expanded rule snapshot to the public `gargantua-rules` repository and documented that the snapshot is not yet full Mole parity.

## [0.1.0] - 2026-04-23

### Added
- Initial public release.
- YAML-driven cleanup and uninstall rules (19 cleanup files / 83 rules, 2 uninstall files / 12 rules).
- MCP server (`GargantuaMCP`) with Phase 2 read-only tools (`scan`, `analyze`, `status`, `explain`, `list_profiles`) and Phase 3 destructive `clean` tool protected by protected-path hard-reject, 60s-per-client rate limit, audit trail, and cancel-notification grace period.
- Privileged helper (`GargantuaPrivilegedHelper`) for operations requiring elevated trust.
- Local AI explainability via MLX Swift for rule explanations — AI can explain a rule's safety classification but cannot lower it.
