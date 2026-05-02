---
name: Gargantua
description: A gravitational Mac cleanup tool for developer systems.
colors:
  void: "#14161A"
  surface-1: "#191B1F"
  surface-2: "#202228"
  surface-3: "#272A30"
  surface-4: "#2E3138"
  ink: "#EDF0F3"
  ink-2: "#9BA4B0"
  ink-3: "#67707E"
  ink-4: "#464A53"
  border: "#FFFFFF12"
  border-soft: "#FFFFFF0A"
  border-em: "#FFFFFF21"
  accent: "#2582F4"
  safe: "#3B9B68"
  review: "#EDA01D"
  protected: "#C62F2F"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: "0"
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "0"
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "0"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: "0"
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: "0"
  caption:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.3
    letterSpacing: "0"
  section-label:
    fontFamily: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.8px"
  mono-data:
    fontFamily: "SFMono-Regular, ui-monospace, Menlo, Monaco, Consolas, monospace"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: "0"
  mono-path:
    fontFamily: "SFMono-Regular, ui-monospace, Menlo, Monaco, Consolas, monospace"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.25
    letterSpacing: "0"
rounded:
  sm: "4px"
  md: "6px"
  lg: "8px"
spacing:
  space-1: "4px"
  space-2: "8px"
  space-3: "12px"
  space-4: "16px"
  space-5: "24px"
  space-6: "32px"
  space-7: "48px"
  space-8: "64px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "8px 16px"
  button-secondary:
    backgroundColor: "{colors.surface-3}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "8px 16px"
  button-danger:
    backgroundColor: "{colors.protected}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "8px 16px"
  card:
    backgroundColor: "{colors.surface-1}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "16px"
  chip:
    backgroundColor: "{colors.surface-3}"
    textColor: "{colors.ink-2}"
    typography: "{typography.caption}"
    rounded: "{rounded.sm}"
    padding: "4px 12px"
  sidebar-item-selected:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.md}"
    padding: "8px 16px"
---

# Design System: Gargantua

## 1. Overview

**Creative North Star: "The Event Horizon Console"**

Gargantua is a dark, precise product interface for developer Mac owners who want to clear accumulated build artifacts, caches, duplicates, and model debris without second-guessing the tool. The interface should feel like a space-cold terminal that grew up: dense, file-literate, and calm under pressure.

Trust is the visual product. Color is classification first and decoration never. Warm safety signals are rare against a cold void; blue is reserved for direct interactivity and focus. Surfaces pull attention inward through borders, tonal contrast, and compact hierarchy, not glow.

The system explicitly rejects CleanMyMac X marketing polish, generic dashboard templates, glassmorphism, and neon-on-dark AI aesthetic. It should read as a native Mac utility for people who understand file paths, not a subscription landing page wearing a cleaner costume.

**Key Characteristics:**
- Dark mode primary, tuned for developers working between coding sessions.
- Restrained color, one interaction accent, warm safety states, no decorative palette.
- Dense information with strong hierarchy: paths, sizes, confidence, and safety stay visible.
- System fonts for UI, monospaced type for paths and byte counts.
- Borders and tonal layers only. No shadows, no glass, no glow.

## 2. Colors

The palette is a cold void with warm trust signals. Neutrals carry most of the surface; accent and safety colors appear only when they mean action or risk.

### Primary
- **Hawking Blue**: the sole interactive accent. Use it for primary buttons, active segmented controls, focus borders, links, and current navigation indicators. Its rarity is part of the trust model.

### Secondary
- **Terminal Green**: safe cleanup, native readiness, and low-risk confirmation states.
- **Accretion Amber**: review-tier cleanup, warnings, partial scans, and attention states that are not destructive.

### Tertiary
- **Red Ember**: protected items, destructive delete, denied permissions, and irreversible-risk states. Never use it for visual emphasis alone.

### Neutral
- **Void**: app canvas and sidebar ground.
- **Outer Surface**: main panels and baseline cards.
- **Inner Surface**: rows, metric cells, selected navigation, and list containers.
- **Raised Surface**: controls, secondary buttons, dropdown-like surfaces, and modal bodies.
- **Top Surface**: hover and tooltip layer.
- **Star Ink**: primary readable text.
- **Dim Star Ink**: descriptions, secondary labels, and body support text.
- **Nebula Ink**: tertiary metadata and inactive icons.
- **Dormant Ink**: disabled, placeholder, and low-emphasis status text.
- **Border Field**: white-alpha separators. Borders are structural, not decorative.

### Named Rules
**The Classification Rule.** Safe, review, and protected colors belong only to safety classification, system state, or cleanup risk. They are prohibited as decoration.

**The Blue Means Click Rule.** Hawking Blue means direct interaction, focus, or current selection. Do not use it for static illustration.

**The Void Holds Still Rule.** Backgrounds stay in the neutral stack. Do not introduce purple gradients, beige warmth, neon glows, or glass tints.

## 3. Typography

**Display Font:** System sans, SF Pro on Apple platforms.
**Body Font:** System sans, SF Pro on Apple platforms.
**Label/Mono Font:** SF Mono or platform monospace for data and paths.

**Character:** Native, technical, and compact. The type system should disappear into the task until a path, byte count, or safety label needs precision.

### Hierarchy
- **Display** (700, 28px, 1.15): health scores, large metrics, and permission-flow centerpiece numbers.
- **Headline** (600, 16px, 1.25): page titles and compact screen headers.
- **Title** (600, 15px, 1.25): brand header and strong panel names.
- **Body** (400, 13px, 1.35): explanatory text, descriptions, and row context. Keep prose around 65-75 characters per line when it becomes paragraph text.
- **Label** (500, 13px, 1.25): buttons, list item names, field labels, and primary row text.
- **Caption** (400, 11px, 1.3): metadata, timestamps, helper text, and quiet status lines.
- **Section Label** (600, 10px, 0.8px tracking, uppercase): sidebar groups and dashboard sections.
- **Mono Data** (400, 12px, tabular): file sizes, costs, percentages, and aligned metrics.
- **Mono Path** (400, 11px): filesystem paths and commands, truncated from the middle when needed.

### Named Rules
**The Path Precision Rule.** Paths and sizes always use monospace. Do not set file paths in the body font.

**The No Display Labels Rule.** UI labels, buttons, rows, and settings text stay compact. Display scale is reserved for metrics and dedicated hero-like permission moments.

## 4. Elevation

Gargantua uses tonal layering and borders instead of shadows. Depth is created by moving from Void to Surface 1 through Surface 4, then adding a one-pixel border when an edge must be trusted. Modals use a dark scrim plus a Surface 3 body, still without cast shadow.

### Named Rules
**The No Point Light Rule.** Shadows are forbidden as the default elevation language. In this product, surfaces separate by tone, border, and placement.

**The Border Is Evidence Rule.** Borders confirm structure. Use standard Border for containers, Border Soft for internal dividers, Border Em for active control outlines, and Border Focus for keyboard focus.

## 5. Components

Components are dense, squared-off, and native. Every control should be legible in dark mode without relying on glow.

### Buttons
- **Shape:** compact rounded rectangle (4px radius).
- **Primary:** Hawking Blue fill, label typography, white or Star Ink text, 8px vertical and 16px horizontal padding.
- **Hover / Focus:** focus uses a 2px Hawking Blue stroke. Hover may lift tone one surface step but must not animate layout.
- **Secondary / Ghost:** Surface 3 fill or transparent fill with Border Em stroke. Use for refresh, cancel, and low-risk secondary actions.
- **Danger:** Red Ember fill or red-tinted background only for delete, revoke, protected override, or destructive confirmation.

### Chips
- **Style:** Surface 3 fill, Dim Star Ink text, caption type, compact horizontal padding.
- **State:** chips summarize evidence and metadata. They are not decorative badges and should not compete with safety states.

### Cards / Containers
- **Corner Style:** compact radius (6px). Modals may use 8px.
- **Background:** Surface 1 for primary panels, Surface 2 for rows and selected nav, Surface 3 for controls and raised surfaces.
- **Shadow Strategy:** no shadows. Use borders and tonal contrast only.
- **Border:** one-pixel Border for panel edges, Border Soft for internal dividers.
- **Internal Padding:** 16px standard, 24px only for major recommendation or modal content.

### Inputs / Fields
- **Style:** Surface 3 fill, 4px radius, one-pixel Border Soft stroke.
- **Focus:** 2px Hawking Blue focus ring. Never use glow or blur.
- **Error / Disabled:** Review Amber for fixable warnings, Red Ember for destructive or blocked states, Dormant Ink for disabled text.

### Navigation
- **Style:** 200px dark sidebar, section labels in uppercase 10px type, SF Symbols at 16px.
- **Default:** transparent row, inactive icon in Nebula Ink, label in Dim Star Ink.
- **Hover:** Surface 1 background.
- **Active:** Surface 2 background, Border Em outline, and a 3px Hawking Blue capsule indicator at the leading edge.

### Scan Rows
- **Style:** dense horizontal rows with confidence bars, checkbox, item name, explanation, path, and size.
- **Safety tint:** row background uses 12% Safe, Review, or Protected tint. This tint is classification, not ornament.
- **Focus:** 2px Hawking Blue stroke with 1px inset padding.
- **Data:** item size uses Mono Data, path uses Mono Path and middle truncation.

### Segmented Controls
- **Style:** Surface 1 or Surface 2 track, 4px radius, no native segmented control if contrast collapses.
- **Selected:** Hawking Blue fill with white text.
- **Unselected:** visible neutral surface with Dim Star Ink text. Every option must look clickable.

### Signature Component
**Confidence Orbit:** the trust indicator appears as compact ascending bars or circular arcs. It communicates confidence percentage through shape and safety through color. Never replace it with a generic progress ring unless the exact confidence and safety roles remain visible.

## 6. Do's and Don'ts

### Do:
- **Do** use Void, Surface 1, Surface 2, Surface 3, and Surface 4 as the complete depth ladder.
- **Do** reserve Hawking Blue for actions, links, focus, and current selection.
- **Do** keep safety colors tied to the Trust Layer: safe, review, protected.
- **Do** show file paths, sizes, confidence, and safety together when cleanup decisions are being made.
- **Do** use SF Symbols for tool and navigation icons, aligned to fixed-size icon slots.
- **Do** use 4px spacing increments and compact radii. Density is allowed when hierarchy is clear.
- **Do** make empty and loading states quiet, useful, and native.

### Don't:
- **Don't** use CleanMyMac X marketing polish, oversized lifestyle hero sections, or subscription-cleaner gloss.
- **Don't** use generic dashboard templates with equal-weight metric cards and decorative charts.
- **Don't** use glassmorphism, blur panels, frosted cards, or translucent decoration.
- **Don't** use neon-on-dark AI aesthetic, purple-blue gradients, glowing outlines, or bokeh backgrounds.
- **Don't** use shadows as elevation. Borders and tonal layers are the system.
- **Don't** use safety colors for decoration, badges without risk meaning, or arbitrary category color.
- **Don't** hide paths or byte counts behind hover. Evidence must be visible when trust decisions happen.
- **Don't** make cards inside cards. Group with sections, dividers, and full-width bands instead.
