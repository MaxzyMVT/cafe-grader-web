---
description: Learn project front-end styling by reading style files
---

# Design Principles

## Goal
Maintain visual consistency and adhere to the project's design system.

## Context
Use these principles whenever modifying the user interface or adding new styles.

## Steps
1. **Theming**:
   - Always follow the design styles defined in `app/assets/stylesheets/themes/`.
   - Ensure components are compatible with both light and dark themes if applicable.
2. **Global Styles**:
   - Adhere to the variables and utility classes defined in `app/assets/stylesheets/globals.scss`.
   - Use existing design tokens for colors, spacing, and typography instead of hardcoded values.
3. **Consistency**:
   - When building new components, match the look and feel of existing high-quality UI elements in the repository.
