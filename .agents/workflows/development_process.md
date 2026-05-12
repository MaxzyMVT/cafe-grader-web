---
description: Guideline for git version control
---

# Development Process

## Goal
Ensure consistent commit messages, branching strategy, and deployment flow.

## Context
Use these rules whenever making changes to the codebase or interacting with git.

## Steps
1. **Conventional Commits**: 
   - Use simple conventional commit names: `feat: ...`, `fix: ...`, `style: ...`, `refactor: ...`.
   - Avoid unnecessary details in parentheses (e.g., prefer `feat: add points column` over `feat(UI/Engine): add points column`).
2. **Branching**:
   - For large and grouped features or fixes, work on a new branch with a conventional branch name (e.g., `feature/viva-exam-v2`, `fix/grading-engine-stability`).
   - For small, one-off requests, continuing on the current branch is acceptable unless specified otherwise.
3. **No Automatic Pushing/Merging**:
   - Do NOT push to remote, merge branches, or create Pull Requests unless explicitly instructed by the USER.
4. **Amend Related Changes**:
   - If a new change is closely related to the previous commit (e.g., fixing a minor oversight or bug in that commit), use `git commit --amend` instead of creating a new commit to keep the history clean.
