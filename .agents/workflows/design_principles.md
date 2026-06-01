---
description: Learn project front-end styling by reading style files, and what steps need to do if there are some UX / UI changes.
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
4. **Asset Deployment & Hot Reload**:
   - In production environments, assets are served precompiled. After any CSS, JS, or HAML UI/UX updates, always clobber old precompiled assets, run fresh asset precompilation, and touch `tmp/restart.txt` to trigger a Passenger reload and force a full asset refresh:
     ```bash
     PATH="/home/grader_admin/.rbenv/shims:$PATH" bin/rails assets:clobber RAILS_ENV=production
     PATH="/home/grader_admin/.rbenv/shims:$PATH" bin/rails assets:precompile RAILS_ENV=production
     touch tmp/restart.txt
     ```