# Agent Guidelines

Conventions for AI coding agents (and humans) working in this repository.

## Project context

Volatoo is a Gentoo-based distribution that boots into a tmpfs root. Read `README.md` for the architecture and `ROADMAP.md` for current phase before making changes — work should map to a roadmap item, or update the roadmap first.

## Commits

- **Do NOT add `Co-Authored-By` trailers or any AI-attribution lines to commit messages.** No "Generated with", no session links. Commit messages contain only the change description.
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `ci:`, `refactor:`, `chore:`. Scope by component when it helps: `feat(initramfs): …`, `fix(persist): …`.
- Subject line in English, imperative mood, ≤ 72 chars. Body explains *why* when the change isn't obvious.
- Commit directly to `main` for docs; use feature branches once there is code.

## Code conventions

- Shell is the primary language (initramfs, build scripts): POSIX sh inside the initramfs (no bashisms — busybox must run it), bash allowed for host-side tooling. All shell must pass `shellcheck`.
- Ebuilds follow Gentoo's skel and `pkgcheck` cleanly.
- Keep the initramfs minimal: every binary added to it must be justified in a comment in the generator config.

## Boundaries

- Never commit built artifacts: images, squashfs, ISOs, kernels (see `.gitignore`).
- Destructive host operations (partitioning, writing to block devices) only in scripts that require an explicit device argument — never auto-detect a target disk to write to.
- QEMU is the test target. Don't assume the host is Gentoo or Linux; host-side tooling may be run from macOS.

## Language

- Code, comments, commit messages, and docs: English.
- Conversation with the maintainer: 中文 or English, follow their lead.
