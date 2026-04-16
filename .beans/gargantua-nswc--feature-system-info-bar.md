---
# gargantua-nswc
title: 'Feature: System Info Bar'
status: completed
type: feature
priority: normal
tags:
    - area:frontend
    - pasiv
created_at: 2026-04-15T00:45:58Z
updated_at: 2026-04-16T02:24:52Z
parent: gargantua-qne2
---

Compact footer showing hardware, engine status, and MCP status.

## Goals
- Hardware: "MacBook Pro M4 · macOS 15.2 · 380 / 500 GB used"
- Engine status: which engine active (Mole/Native), tool versions, errors
- MCP: running/stopped indicator (Phase 1 prep)

## Scope
**In Scope:** Hardware info display, engine status indicator, disk usage bar
**Out of Scope:** MCP server controls (Settings), detailed tool version management

## Summary of Changes\n\nReplaced simple SystemInfoBadge with full SystemInfoBar:\n- Line 1: Hardware model (via sysctl) + macOS version\n- Line 2: Disk used / total GB\n- Line 3: Engine status (Mole green/gray dot) + MCP status (always gray, Phase 1 prep)\n\nFiles changed: Sources/GargantuaCore/Views/SidebarView.swift
