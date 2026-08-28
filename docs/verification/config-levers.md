# Claude Code configuration lever verification

Audience: maintainer verification.

This record supports Sea Trials issue #4.
Before any evaluation compares outcomes across spawned-session configurations, the configuration levers that vary between conditions must behave as documented on a real host.
Otherwise every downstream number is unverifiable.
Each claim below is a dated, reproduced observation, not a restatement of the documentation.
Exact task chronology and this session's private working paths stay out of this page.
Commands are given with the working directory named generically as `<ruff>` (a shallow clone of `astral-sh/ruff`) and the config sandbox as `<sandbox>`.

## Host and version pin

**Unverified:** This page was produced on Ubuntu 24.04.4 LTS, not Fedora.
The available execution environment for this task had no Fedora host.
Every observation below is Claude Code CLI behavior implemented in cross-platform bundled JavaScript, and no OS-conditional branch was found for any lever tested, so there is no specific reason to expect Fedora to diverge.
That expectation is itself unverified and should be spot-checked on an actual Fedora host before being treated as load-bearing.

**Verified 2026-08-28:** Two separate Claude Code installations existed on the test host, and the one that `claude` resolves to on `PATH` was not the one a naive `npm ls -g` or source-grep inspection would find.

```sh
which -a claude               # /opt/node22/bin/claude -> symlink -> /opt/claude-code/bin/claude
npm ls -g --depth=0           # @anthropic-ai/claude-code@2.1.42  (a separate, older install)
claude --version               # 2.1.250 (Claude Code)
node /opt/node22/lib/node_modules/@anthropic-ai/claude-code/cli.js --version   # 2.1.42 (Claude Code)
```

`/opt/claude-code/bin/claude` is a self-contained, roughly 212 MiB native (Bun-compiled) executable, not the npm package.
It is the one every command in this page actually ran.
A static grep of the npm package's `cli.js` for hook or setting names (`InstructionsLoaded`, `claudeMdExcludes`) found nothing, which would have wrongly concluded those levers don't exist.
They exist and behave as documented in the binary that `claude` actually runs, confirmed below with `strings` and with live behavior.
Lesson for reproduction: pin and log `which -a claude` and `claude --version` together before trusting any other observation on a host that might have more than one install on `PATH`.

## Sandbox environment caveats

Read this section before reusing any command on this page.
Every command below runs Claude Code from inside a running Claude Code session, so the parent session's environment leaks into the child unless explicitly stripped.
Three leaks were load-bearing enough to change results and had to be suppressed with `env -u ...` for every run in this page.

**Verified 2026-08-28:**

- `CLAUDE_CODE_REMOTE=true` is set ambiently.
  The bundled auto-memory gate reads it directly: `if($6(process.env.CLAUDE_CODE_REMOTE)&&!process.env.CLAUDE_CODE_REMOTE_MEMORY_DIR)return!1`.
  A session that inherits `CLAUDE_CODE_REMOTE=true` without also setting `CLAUDE_CODE_REMOTE_MEMORY_DIR` has auto memory force-disabled regardless of `autoMemoryEnabled` or `CLAUDE_CODE_DISABLE_AUTO_MEMORY`.
  Left in place, every auto-memory test below would have "confirmed" auto memory was off no matter what was configured.
- `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` is set ambiently.
  It silently changes `--add-dir` from "does not load CLAUDE.md" (the documented default) to "loads it" the moment `--add-dir` is used.
- The process runs as `root`.
  `--dangerously-skip-permissions` refuses to run as root or under sudo "for security reasons", so every write-triggering test below used `--allowedTools "Write"` instead.

**Unverified:** whether an ordinary non-root, non-remote Fedora session has any other ambient environment variable that shapes these levers was not checked.
Only the three above were caught because they visibly changed results.

**Verified 2026-08-28:** `$HOME` (`/root`) carries this account's real `~/.claude/skills`, `~/.claude/settings.json`, and so on.
Tests that care about isolating what a project, user, or CLI source actually contributes used `CLAUDE_CONFIG_DIR=<sandbox>` pointed at an empty scratch directory rather than relying on `--setting-sources` alone, specifically to avoid this account's real skills and settings answering the question instead of the lever under test.

## Observation methods used, and one that doesn't work everywhere

**Verified 2026-08-28:** three independent, non-inferential observation methods were used, matching the issue's instruction not to rely on the model's own account of its context.

1. The `InstructionsLoaded` hook.
   It exists and fires in the binary Claude Code actually runs, confirmed both by `strings -a claude | grep InstructionsLoaded` returning 14 matches and by live firing below.
   Its stdin JSON payload, captured verbatim:

   ```json
   {"session_id":"<uuid>","transcript_path":"<path>.jsonl","cwd":"<ruff>","hook_event_name":"InstructionsLoaded","file_path":"<ruff>/CLAUDE.md","memory_type":"Project","load_reason":"session_start"}
   {"session_id":"<uuid>","transcript_path":"<path>.jsonl","cwd":"<ruff>","hook_event_name":"InstructionsLoaded","file_path":"<ruff>/AGENTS.md","memory_type":"Project","load_reason":"include","parent_file_path":"<ruff>/CLAUDE.md"}
   ```

   Fields observed across all runs in this page: `session_id`, `transcript_path`, `cwd`, `hook_event_name` (always the literal string `"InstructionsLoaded"`), `file_path`, `memory_type` (`"Project"` was the only value seen; user- and local-scope files were not exercised against this field), `load_reason` (`"session_start"` for a file loaded directly at launch, `"include"` for a file pulled in via `@path` import), and `parent_file_path` (present only on an `"include"` load, naming the file that imported it).
   This is the schema later Sea Trials steps should code against.
   `SessionStart` also fires and exists in the bundled binary, confirmed by 17 references via `strings`.
   Its payload is `{session_id, transcript_path, cwd, hook_event_name:"SessionStart", source:"startup"}` and it carries no information about which memory files loaded.
   `InstructionsLoaded` is the hook that answers that question, not `SessionStart`.
2. `/context`, run non-interactively as the entire prompt in `-p`/print mode (`claude -p "/context" --output-format json ...`).
   This works and is cheap: it renders the full `## Context Usage` table (System prompt, System tools, Memory Files, Skills, Custom Agents, each with token counts and, for Memory Files and Skills, per-item source) without spending a real model turn once the client-side computation is bare-mode-eligible.
   This was the primary evidence source for every lever except auto memory and MCP.
3. Local transcript files (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, or under `$CLAUDE_CONFIG_DIR/projects/...`) were checked and found not to contain a visible, separate "here is CLAUDE.md" user-role message.
   The on-disk transcript's `user` entry held only the literal prompt text.
   CLAUDE.md and AGENTS.md injection is reconstructed into the outbound API request at send time rather than persisted as its own transcript turn.
   Do not use local transcript inspection as evidence that memory files did or didn't load.
   Only the `InstructionsLoaded` hook and `/context` are authoritative for that, exactly as the issue instructed.

**Verified 2026-08-28, `/context` goes dark under `--bare`:** with `--bare`, `claude -p "/context" --output-format json` returns `is_error:false`, `num_turns:0`, `total_cost_usd:0`, and a `result` of exactly:

```text
## Context Usage

**Model:** claude-haiku-4-5-20251001
**Tokens:** 0 / 200k (0%)
```

Every category table is absent, not merely zeroed.
This is a distinct code path from a real answer with small numbers; compare the `--safe-mode` result in the next section, which populated real numbers via the same command.
A later Sea Trials step that runs `/context` as its `--bare` observation method will get this degenerate stub back and must not read it as "nothing loaded".
It means `/context`'s own introspection did not run under `--bare`.
Use the `InstructionsLoaded`/`SessionStart` hook log for `--bare` instead (also empty here, but truthfully so; see below).

## `--safe-mode`

**Verified 2026-08-28** against the pinned binary above, run as `claude -p "/context" --output-format json --settings <probe-hooks-file> --safe-mode` in `<ruff>`.

- The probe hook log, registering both `SessionStart` and `InstructionsLoaded` through `--settings` (the topmost precedence tier), recorded zero firings.
  Safe mode disables hooks regardless of which settings tier registered them, including the CLI's own `--settings` file.
  This is a stronger guarantee than "project/user hooks are disabled" and is worth stating explicitly, since `--settings`-tier hooks are the one thing most other levers in this page could not suppress.
- `/context` returned real, non-degenerate numbers (`System prompt 3.9k`, `System tools 17.7k`, and so on), confirming the session itself ran normally.
  This is not the `--bare` stub above.
- No `### Memory Files` section appeared at all: CLAUDE.md and AGENTS.md were not loaded.
- The `### Skills` table listed only the product's own built-in skills (`design`, `dataviz`, `code-review`, and so on).
  Every `User`-sourced skill (this account's real `~/.claude/skills`) and every `claude.ai sync`-sourced skill were absent.
  This is a real nuance the documentation's "skills ... disabled" phrasing glosses over: built-in skills still resolve under `--safe-mode`, and only user, project, and synced skill sources are disabled.
  A test that checks whether skills are off by asking whether any skill loaded will get a false negative for safe mode.
- Auth and model selection worked normally.
  This is the one lever in this page whose `-p` calls succeeded without supplying an API key, matching the documented "Auth, model selection, built-in tools, and permissions work normally."

## `--bare`

**Verified 2026-08-28**, same probe, `--bare` in place of `--safe-mode`.

- The probe hook log was again empty: hooks disabled, same as `--safe-mode`.
- `/context` returned the degenerate all-zero stub described above rather than a populated table, so Memory Files and Skills exclusion could not be directly re-confirmed through `/context` for `--bare` the way it was for `--safe-mode`.
  The hook log's silence is the evidence that stands for `--bare` instead.
- `--bare` genuinely could not be exercised end to end in this sandbox.
  A plain, non-slash prompt under `--bare` failed with `is_error:true`, `result:"Not logged in · Please run /login"`.
  This reproduces the documented claim verbatim: "Anthropic auth is strictly `ANTHROPIC_API_KEY` or `apiKeyHelper` via `--settings` (OAuth and keychain are never read)."
  This session authenticates via OAuth and keychain, which `--bare` correctly refused to read, and no `ANTHROPIC_API_KEY` was available to supply instead.

**Unverified as a result:** LSP, background prefetches, and keychain-read suppression under `--bare` could not be observed here beyond the auth refusal itself.
That refusal, rather than a silent read, is already the strongest possible confirmation of the keychain sub-claim.
Any environment that will actually exercise `--bare` behaviorally needs an `ANTHROPIC_API_KEY` or `apiKeyHelper` supplied up front.
OAuth-authenticated accounts, which is what an interactive Fedora dev machine normally is, hit this same wall, so downstream Sea Trials steps that plan to run real `--bare` sessions should budget for provisioning a key.

## `--setting-sources` and each omission

**Verified 2026-08-28.**
Test fixture: a probe hook registered at three independent tiers.
`<ruff>/.claude/settings.json` is ruff's own, pre-existing, real project config, left unmodified.
A `LocalLevelSessionStart` hook was added to `<ruff>/.claude/settings.local.json`.
A `UserLevelSessionStart` hook was added to `<sandbox>/settings.json` with `CLAUDE_CONFIG_DIR=<sandbox>`.
`InstructionsLoaded` and plain `SessionStart` were registered via `--settings` (command-line tier, orthogonal to `--setting-sources` per the documented precedence table), and observed to fire in every combination below regardless of source list.

| `--setting-sources` value | `UserLevelSessionStart` fired | `LocalLevelSessionStart` fired | `InstructionsLoaded` fired / Memory Files shown |
|---|---|---|---|
| `user,project,local` (all) | no (real `$HOME`, sandbox marker not applicable) | yes | yes / CLAUDE.md + AGENTS.md |
| `user,local` (omit `project`) | yes | yes | no / absent entirely |
| `user,project` (omit `local`) | yes | no | yes / CLAUDE.md + AGENTS.md |
| `project,local` (omit `user`) | no | yes | yes / CLAUDE.md + AGENTS.md |

Each omission produced exactly the negative evidence expected and nothing else changed.
Omitting `project` removed both the project's CLAUDE.md/AGENTS.md chain and its hook.
Omitting `local` removed only the local-settings hook.
Omitting `user` removed only the user-settings hook.
This matches the documented precedence table and the documented rule that project rules, and, confirmed here, project CLAUDE.md, are skipped when `project` is excluded.

## `claudeMdExcludes`

**Verified 2026-08-28.**
`<ruff>/CLAUDE.md` is `@AGENTS.md`, a single-line import, so this is also an import-exclusion test, not just a top-level-file test.
With

```json
{ "claudeMdExcludes": ["<ruff-absolute-path>/AGENTS.md"] }
```

passed via `--settings`, `InstructionsLoaded` fired exactly once (`CLAUDE.md`, `load_reason:"session_start"`) instead of twice: the `AGENTS.md` `include` event was absent.
`/context`'s Memory Files table showed only `CLAUDE.md` (12 tokens), with `AGENTS.md` (previously 4k tokens) gone entirely.
Both the hook log and `/context` agree, and the pattern was matched as an absolute path exactly as documented ("Patterns are matched against absolute file paths using glob syntax").

## Auto memory: `CLAUDE_CODE_DISABLE_AUTO_MEMORY` and `autoMemoryEnabled: false`

**Verified 2026-08-28.**
With `CLAUDE_CODE_REMOTE` unset (see sandbox caveats above) and `CLAUDE_CONFIG_DIR=<sandbox>`, a prompt explicitly instructing the model to persist a preference ("Use your memory-saving mechanism now, don't just acknowledge in chat") was run with `--allowedTools "Write"`.

- Baseline, neither lever set: the model wrote `<sandbox>/projects/<encoded-ruff-path>/memory/MEMORY.md` and a topic file `feedback_commit_messages.md`, and its chat reply confirmed the save.
- `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`: no new file was written, and a fresh sandbox run with only this lever set produced no `memory/` directory at all.
  The model's own reply stated it had no memory-saving tool available in this conversation.
- `{"autoMemoryEnabled": false}` in `<sandbox>/settings.json` (project/user settings layer, independent of the env var): same result.
  No `memory/` directory was created, and the model reported no memory tool available.

Both levers are confirmed to remove the underlying tool from the model entirely, not merely instruct the model to decline.
That is the strongest form of "disabled": a prompt injection or model mistake cannot route around it the way a CLAUDE.md instruction could.

## `--strict-mcp-config`

**Verified 2026-08-28**, raw commands and output, exactly as observed:

```sh
# <ruff>/.mcp.json contains one server, "project-fake": { "command": "/bin/false" }
claude mcp list
#   project-fake: /bin/false  - Pending approval (run `claude` to approve)

claude --strict-mcp-config mcp list
#   project-fake: /bin/false  - Pending approval (run `claude` to approve)     <- unchanged
```

**Unverified, not isolated:** taken at face value this looks like `--strict-mcp-config` failed to suppress the project `.mcp.json` server, contradicting "ignoring all other MCP configurations."
Three confounds prevent treating that as a confirmed defect.

1. `--mcp-config <configs...>` is a variadic CLI option and, placed before the `mcp list` subcommand, silently swallowed the literal tokens `mcp` and `list` as additional, nonexistent config file paths, producing `MCP config file not found: <ruff>/mcp` and `.../list`.
   Any reproduction of this test must place a non-variadic flag (`--strict-mcp-config` itself works) immediately after `--mcp-config <file>` to terminate the variadic collection, or the subcommand never runs at all.
   This is a real, separate CLI-parsing gotcha worth recording on its own: `--mcp-config` followed directly by a subcommand name silently eats the subcommand.
2. Even once that parsing hazard is avoided, `claude mcp list` may be a static config-inspection utility that always reports the full merged, on-disk configuration regardless of session-scoped runtime flags like `--strict-mcp-config`, rather than reflecting what an actual agentic session would connect to.
   That would make the observed "unchanged" output a mismatch between the inspector and runtime behavior, not evidence that runtime filtering itself is broken.
3. The project server never moved past "Pending approval" in any run, because headless (`-p`) sessions have no path to satisfy the interactive per-project trust dialog that ungates a new project's MCP servers (see next section).
   No run in this page ever observed a live, connected MCP server to check tool availability against, which is the only fully conclusive test of `--strict-mcp-config`'s real effect.

Later Sea Trials steps should re-test this with a live, already-trusted MCP server instead of `/bin/false`, and by asking the running session which MCP tools are available rather than via `mcp list`, before relying on `--strict-mcp-config` for isolation.

## Headless-mode trust gate

This is an adjacent finding, not one of the seven documented levers.

**Verified 2026-08-28.**
Independent of every lever above, `-p`/print-mode sessions in this environment never load a project-declared plugin.
`<ruff>/.claude/settings.json` declares and enables the `ty-skills` plugin, four real skills (`adding-ty-diagnostics`, `minimizing-ty-ecosystem-changes`, `summarise-ecosystem-results`, `wobbling-ty-constraint-order`), via `.agents/.claude-plugin/marketplace.json`.
In every baseline run in this page, full `--setting-sources`, real `$HOME`, no exclusions, `/context`'s Skills table never contained any of those four names, only built-in, user, and synced skills.
The most likely explanation, consistent with the MCP trust-dialog message above ("Pending approval, run `claude` to approve"), is that new-project plugin and MCP trust requires an interactive approval this headless mode cannot present, and headlessly defaults to not-loaded rather than auto-approving.
This was not chased to a definitive mechanism and is flagged here as **Unverified**: any Sea Trials step that plans to exercise project-scoped plugins or MCP servers headlessly needs to first establish how, or whether, that trust gate can be pre-satisfied non-interactively, or those levers will silently read as off no matter how they are configured.

## `CLAUDE_CONFIG_DIR`

**Verified 2026-08-28.**
With `CLAUDE_CONFIG_DIR=<sandbox>`, an otherwise-empty directory seeded only with marker files, and every other ambient leak stripped, a single `/context` run against `<sandbox>/skills/marker-skill/SKILL.md`, `<sandbox>/commands/marker-cmd.md`, and `<sandbox>/agents/marker-agent.md` showed the following.

- `### Custom Agents`: `marker-agent | User | 17` tokens, relocated.
- `### Skills`: `marker-skill | User` and `marker-cmd | User` both present.
  Every built-in and `claude.ai sync` skill was still present, since those come from the product or account, not from `$HOME`, and are unaffected by `CLAUDE_CONFIG_DIR`.
  No skill or command from the real `$HOME` (`/root/.claude/skills/...`) appeared, confirming relocation rather than a merge.
- Settings relocated: a `SessionStart` hook placed only in `<sandbox>/settings.json` fired, per the `--setting-sources` matrix above, which used this same sandbox as its "user" tier.
- The session transcript path and the auto-memory directory both relocated under `<sandbox>/projects/<encoded-cwd>/...`, confirmed in both the `--setting-sources` runs and the auto-memory runs above, rather than under the real `~/.claude/projects/...`.

All four things the issue asks `CLAUDE_CONFIG_DIR` to be confirmed against, settings, skills, agents, commands, and the `projects/` auto-memory directory, relocated together as one unit, with nothing observed left behind at the real `$HOME`.

## Open follow-ups for later Sea Trials steps (#5, #6, #8)

- Re-run this page's Fedora-specific claim on an actual Fedora host.
  Nothing here found OS-conditional code, but that was not exhaustively proven.
- Resolve the `--strict-mcp-config` and plugin-trust boundary above with a live, pre-trusted server before depending on MCP isolation between conditions.
- If any downstream step plans to run real `--bare` sessions, provision `ANTHROPIC_API_KEY` or an `apiKeyHelper` up front.
  OAuth-authenticated accounts cannot exercise `--bare` at all otherwise.
- Always log `which -a claude` and `claude --version`, and, if ambiguous, `strings -a "$(which claude)" | grep -c <symbol>`, as part of any run's recorded evidence, given this host's two-installation trap.
