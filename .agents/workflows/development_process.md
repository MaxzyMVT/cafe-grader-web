---
description: Guideline for git version control
---

# Development Process

## Goal
Ensure consistent commit messages, branching strategy, and deployment flow.

## Context
Use these rules whenever making changes to the codebase or interacting with git.

## Steps
1. **Research Conventions**:
   - Before committing, use `git log -n 10` to observe the project's specific commit history and naming conventions.
   - If git history is inaccessible, adhere strictly to the **Conventional Commits** rules below as the default standard.
2. **Conventional Commits**:
   - **Format**: `<type>(<optional scope>): <description>`
   - **Types**: 
     - `feat`: new features.
     - `fix`: bug fixes.
     - `refactor`: code changes that neither fix a bug nor add a feature.
     - `perf`: code changes that improve performance.
     - `style`: changes that do not affect the meaning of the code (white-space, formatting, etc).
     - `test`: adding missing tests or correcting existing tests.
     - `docs`: documentation only changes.
     - `build`: changes that affect the build system or external dependencies.
     - `ops`: changes to infrastructure, deployment, CI/CD, etc.
     - `chore`: other changes that don't modify src or test files.
   - **Description Rules**: 
     - Use imperative, present tense: "change" not "changed" nor "changes".
     - Do not capitalize the first letter.
     - Do not end the description with a period.
   - **Breaking Changes**: Indicated by an `!` before the colon (e.g., `feat(api)!: remove endpoint`).
3. **Branching**:
   - **Format**: `<type>/<description>`
   - **Types**: `feature/` (or `feat/`), `bugfix/` (or `fix/`), `hotfix/`, `release/`, `chore/`.
   - **Description Rules**:
     - Use lowercase alphanumerics, hyphens, and dots. 
     - Avoid spaces, underscores, or other special characters.
     - Do not use consecutive, leading, or trailing hyphens or dots.
     - Keep it clear and concise (e.g., `feature/add-login-page`).
   - **Trunk Branches**: `main`, `master`, or `develop` do not require a prefix.
4. **No Automatic Pushing/Merging**:
   - Do NOT push to remote, merge branches, or create Pull Requests unless explicitly instructed by the USER.
5. **Amend Related Changes**:
   - If a new change is closely related to the previous commit (e.g., fixing a minor oversight or bug in that commit), use `git commit --amend` instead of creating a new commit to keep the history clean.
6. **Pull Requests**:
   - When instructed to create a Pull Request, provide a highly descriptive description.
   - The description MUST summarize all key functional and technical changes made in the branch.
   - You DO NOT need to list the commits in the description, as git already tracks them. Only cross-reference specific commits if there is a critical reason to highlight one.
   - Avoid generic descriptions like "Update code"; instead, explain *what* was changed, *why*, and any implications for the system.
