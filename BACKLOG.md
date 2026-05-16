# Backlog

Things to implement or decide for this repo. In no particular order;
move items out when they're done or scrapped.

## Open

### Bring local agent CLI state into clones at create time

**Status:** Claude Code shipped in 0.1.2 as
`dev-instance create --copy-claude` (allowlist: `settings.json`,
`CLAUDE.md`, `skills/`, `agents/`, `commands/`, `hooks/`, `plugins/`,
`statusline.{sh,js}`, `claude-quota.js`). Codex CLI + OpenCode
equivalents are still to do, plus an umbrella `--copy-settings` flag
once both follow-ups land.

Two smolvm-side gotchas discovered while landing this:

1. ~~**`smolvm machine cp` on `--from <pack>` machines reverts the
   writable filesystem.**~~ **Fixed in smolvm 0.7.0** (filed as
   [smolvm#264](https://github.com/smol-machines/smolvm/issues/264);
   the corresponding `cmd_create` workaround was removed in 0.1.3).
2. **`smolvm machine start --init …` returns before init has
   finished.** Eager `machine exec` after start races init and the
   `dev` user may not exist yet. Still present in 0.7.0; worked
   around with `wait_for_dev_user` (poll `id dev` until it returns
   0). See [`wip/issue-papercuts.md`](wip/issue-papercuts.md)
   entry 1 for the upstream filing draft.

Also worth noting: tar must use `--dereference` so host-side symlinks
in `~/.claude/` (e.g. a `skills/clever-tools` pointing into a project
dir on the host) land as real directories inside the VM, not as
symlinks to host paths that don't exist there.

The umbrella plan: `dev-instance create --copy-settings` (or per-agent
flags) that copies the host's agent CLI state into the new clone so the
experience inside the VM matches what the user already has on the host
— same skills, statusline, theme, MCP servers, agent definitions, slash
commands, and **the agent's own auth** so they're not re-signing-in
every fresh clone.

**Guiding principle: mirror the agent's existing reach, don't expand
it.** The sandbox isolates the agent from the *rest of the host* (other
repos, SSH agent, browser data, host-wide creds the agent doesn't
normally touch). It shouldn't isolate the agent from the things that
make it function — including the credentials it already had access to
on the host. Same agent, less host.

**In scope to copy** (config + personalization + the agent's own auth,
so the VM feels like home and you don't re-sign-in every session):

- Claude Code: `~/.claude/settings.json`, `CLAUDE.md`, `skills/`,
  `agents/`, `commands/`, MCP server config, statusline script, and
  `.credentials.json`. MCP configs that embed API keys come along too
  (the agent legitimately uses them on the host).
- Codex CLI: TBD — locate config + auth files (probably `~/.codex/`).
- OpenCode: `~/.config/opencode/config.json` and any auth state.

**Out of scope — host-specific runtime / history** (copying would bloat
every clone and cross-contaminate projects):

- `~/.claude/sessions/` — REPL session caches.
- `~/.claude/projects/` — per-project conversation logs, keyed by host
  paths that don't map inside the VM.
- `~/.claude/todos/` — runtime task state.
- `~/.claude/statsig/`, `~/.claude/shell-snapshots/`, and any other
  runtime caches.
- Same shape for Codex / OpenCode equivalents.

**Out of scope — would expand the agent's reach** (importing would
extend the agent's authority *beyond* what it has on the host, which
is what the sandbox exists to prevent):

- SSH agent socket, `~/.ssh/`, `~/.aws/`, `~/.kube/`, etc.
- Host environment variables not consumed by the agent.

So the practical rule isn't "everything the agent could touch on the
host" — it's "the agent's config + personalization + its own auth,
nothing else." Two distinct reasons to skip, both end up at skip.

Open questions:

- **Copy vs. mount.** Copy at create time is safer (no live link back
  to the host; changes inside the VM stay inside). Mount keeps things
  in sync but means VM-side edits leak back to the host's config
  files, which is probably not desired.
- **Per-agent flags or umbrella?** Probably both:
  `--copy-settings` copies all three; `--copy-claude` / `--copy-codex` /
  `--copy-opencode` for surgical use.
- **Path mapping inside the VM.** Mirror host paths
  (`/home/dev/.claude/...`) so the agent CLI finds everything without
  extra configuration.
- **Default on or off?** Likely off by default for now — the current
  posture is "explicit opt-in for anything that crosses the boundary"
  and that's a clean default. Could revisit once the feature has been
  exercised.

### Rewrite `dev-instance` in something other than bash?

The script is at 366 lines and growing. Pain points so far:

- JSON parsing via `grep -oE` + `sed`.
- Bash 3.2 compat for macOS hosts (no `mapfile`, careful array
  expansion with `set -u`, etc.).
- Empty-array + `set -u` interactions.

Future features that will amplify the pain: env-var forwarding into
clones, `--copy-settings` (above), interactive prompts beyond the
trivial y/N case, structured config files.

Candidates worth weighing when we hit the limit:

- **Bun + TypeScript.** Fits the project theme — Bun is already a hard
  install dep for using the blueprints, so adding it for the wrapper
  doesn't widen the user-facing surface. `bun build --compile` makes
  a single-binary distribution. Self-referential bonus for the talk
  story.
- **Python.** Universal, ubiquitous, `argparse` is fine for a tool
  this size. Picks up a Python runtime dep (everyone has one) and
  has slight startup cost.
- **Go.** Best distribution story — one static binary, no runtime
  required by the user. More boilerplate per feature; build matrix
  for arm64/x86 + macOS/Linux to maintain.

Stay in bash while the wrapper stays small. Switch when the *next*
feature would be visibly painful in bash, not preemptively.
