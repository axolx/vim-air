# vim-air — Requirements

**vim-air** — Vim AI Review.

## 0. Naming conventions

- R0.1 Repository and plugin name: `vim-air`. Help file `doc/air.txt`, help tag
  `vim-air`.
- R0.2 Primary command: `:Air`. Subordinate commands are `:Air`-prefixed:
  `:AirBuffer`, `:AirParagraph`, `:AirSection`, `:AirAbort`, `:AirClose`,
  `:AirLog`. The motion scope is an operator, `<Plug>AirMotion` (R5.5), not a
  command, since an Ex command cannot take a motion.
- R0.3 Configuration variables use the `g:air_` prefix. There are no
  buffer-local overrides.
- R0.4 Autoload namespace is `air#`, e.g. `air#backend#run()`, `air#submit()`.
- R0.5 The prompt buffer filetype is `air`; the proposal scratch buffer keeps the
  source buffer's filetype (R4.5) and is identified by a buffer variable, not a
  filetype.
- R0.6 Highlight groups and autocommand group MUST be prefixed `Air`.
- R0.7 `<Plug>` mappings MUST be prefixed `<Plug>Air`, e.g. `<Plug>AirRevise`.

## 1. Purpose

A plugin that treats an LLM as a _reviser_: given a prompt and a region of text,
it produces a proposed new version and presents it in Vim's native diff mode so
the user moves between changes with `]c` and `[c` and accepts them into the
source buffer with `do` or `dp`.

Serves both code editing and prose work (writing, copy editing, revision).

## 2. Non-goals

- No floating windows, virtual text, ghost text, or custom review UI.
- No multi-file / agentic editing.
- No chat interface or conversation history UI.
- No Neovim-only APIs.

## 3. Compatibility

- R3.1 MUST work in Vim 8.0+ (classic Vim) as the primary target.
- R3.2 MUST also work in Neovim from the same plugin files. Branching on
  `has('nvim')` is limited to APIs that differ, such as job control.
- R3.3 MUST be pure Vimscript; no Lua, no Python host requirement.
- R3.4 SHOULD work with `+job`/`+channel` for async; MUST degrade to a blocking
  `system()` call when unavailable.
- R3.5 MUST have no plugin dependencies. A shell and each backend's CLI are
  acceptable: the `aws` CLI v2 for Bedrock, curl 8.3+ for OpenAI.

## 4. Core workflow

- R4.1 A command `:Air [prompt]` MUST send the target text plus prompt to
  the configured model.
- R4.2 If no prompt argument is given, the plugin MUST open a prompt buffer for
  composition (see §8a).
- R4.3 The response MUST be placed in a scratch buffer, not applied to the
  original buffer.
- R4.4 The scratch buffer MUST open in a vertical split with `diffthis` active
  in both windows.
- R4.5 The scratch buffer MUST inherit the original buffer's `filetype`,
  `fileencoding`, and `fileformat` so syntax and diffing behave correctly.
- R4.6 The scratch buffer MUST be `nomodifiable` by default (configurable),
  `buftype=nofile`, `bufhidden=wipe`, `noswapfile`.
- R4.7 Accepting changes MUST be done entirely with native Vim diff commands.
- R4.8 A command `:AirAbort` MUST cancel an in-flight asynchronous request.
  The blocking fallback (R3.4) cannot be interrupted this way.
- R4.9 A command `:AirClose` MUST close the diff split, run `diffoff` on
  the original window, and restore diff-related options (`wrap`,
  `foldmethod`, `foldcolumn`, `scrollbind`, `cursorbind`) and the window sizes
  of the tab page as they were before the split. The same restoration MUST
  happen when the proposal is closed with `:quit` or `:bwipeout`.

- R4.10 The plugin MUST allow only one review across the editor. Opening a new
  proposal MUST close the previous review and restore its window settings and
  global `diffopt` before saving the new session. Proposal names include the
  source buffer number.
- R4.11 A response MUST be discarded if the source buffer's change counter
  differs from the value captured when the request was composed. The plugin
  MUST report that the source changed and ask the user to run `:Air` again.

## 5. Target text (scope)

- R5.1 Whole buffer (default for `:Air`).
- R5.2 Visual selection / line range (`:'<,'>Air`). Diff MUST still be
  presented in full-buffer context: the scratch buffer contains the entire
  original buffer with only the selected region replaced.
- R5.3 Current paragraph.
- R5.4 Current Markdown section: from the nearest `#`-style heading (one to six
  `#` and a space) at or above the cursor, through the line before the next
  such heading of the same or higher level. Underlined (setext) headings are
  not recognized, and `#` lines inside fenced code blocks count as headings.
- R5.5 Any motion or text object via the `<Plug>AirMotion` operator, which
  revises the lines between the `'[` and `']` marks it sets, e.g. with
  `nmap <Leader>a <Plug>AirMotion`: `<Leader>aip`, `<Leader>aaf`.
- R5.6 Scope MUST be selectable without leaving the keyboard flow; each scope
  SHOULD have a short command or mapping form.

## 6. Prompts

- R6.1 Named, reusable prompts MUST be definable in config, e.g.
  `let g:air_prompts = {'tighten': '...', 'grammar': '...'}`.
- R6.2 `:Air <name>` MUST resolve to a named prompt when one matches;
  otherwise the argument is treated as a literal prompt.
- R6.3 Ship a small default set of named prompts. Prose: `tighten`, `grammar`
  (copy edit for grammar only), `passive` (reduce passive voice), `cliches`,
  `claims` (soften or qualify unsupported claims), `simplify` and `structure`
  (paragraph order and transitions). Code: `docs`, `modernize` and `refactor`
  (simplify without changing behavior).
- R6.4 The system prompt MUST instruct the model to return only the revised text,
  no commentary, no fences, and to preserve the author's voice unless asked.
  Chat-tuned models otherwise narrate their changes, which would corrupt the
  diff. It MUST be sent as the provider's system field, not prepended to the
  user message (R7.4).
- R6.5 Prompt templates MUST support placeholders for filetype, filename, and
  selected-region markers.
- R6.6 Per-filetype named prompts SHOULD be supported via `g:air_ft_prompts`,
  taking precedence over global prompts of the same name.

## 7. Backend layer

Scope decision: the plugin is built for **multiple backends**. v1 shipped
**AWS Bedrock**, invoked through the `aws` CLI; the **OpenAI API**, called
through `curl`, followed (§7.4).

### 7.1 Architecture

- R7.1 Backends MUST be pluggable. Provider-specific logic MUST live in a
  dedicated file per backend, `autoload/air/backend/<name>.vim`, and MUST NOT
  leak into the dispatcher, scope extraction, prompt composition, or diff logic.
- R7.2 The dispatcher (`autoload/air/backend.vim`) MUST own everything
  provider-agnostic: argv execution, async vs. sync, timeouts, aborting,
  temp-file cleanup, and logging.
- R7.3 A backend MUST implement exactly three functions:
  - `check() -> string` — `''` when usable, otherwise a user-facing reason
    (missing executable, unset model or API key). Called before every
    request so misconfiguration is reported without spawning a process.
  - `request({payload}, {opts}) -> dict` — declares the subprocess: `argv`
    (required), plus optional `stdin`, `cleanup`, `cleanup_dirs`.
  - `parse({result}) -> dict` — maps `{status, stdout, stderr}` onto
    `{ok, text, error, warning}`. Backends own their own error mapping.
- R7.4 The prompt MUST be passed to backends as a structured payload
  (`{'system': ..., 'user': ...}`), not a single pre-concatenated string, since
  providers separate system instructions from the conversation.
- R7.5 `g:air_backend_name` MUST select the backend; default `bedrock`. Adding a
  backend MUST require only dropping a conforming file on the `runtimepath`.
- R7.6 An unknown backend, or one that fails to implement the interface, MUST
  produce a clear error naming the available backends.
- R7.7 A `g:Air_backend` hook MUST bypass the whole layer, so tests and
  non-subprocess transports need no file on disk.

### 7.2 AWS Bedrock backend (v1)

- R7.8 The Bedrock backend MUST invoke the local `aws` CLI and MUST NOT make
  direct HTTP calls or embed SigV4 signing.
- R7.9 It MUST use `aws bedrock-runtime converse`, whose request/response shape
  is uniform across Bedrock models, rather than per-model `invoke-model` bodies.
- R7.10 Credentials MUST be left entirely to the AWS CLI chain (env vars, config
  profiles, SSO, instance/container roles). The plugin MUST NOT read, store,
  prompt for, or forward credentials. `g:air_aws_profile` and `g:air_aws_region`
  MUST be supported as pass-through selectors.
- R7.11 The prompt MUST be passed via `file://` temp files for `--messages`,
  `--system` and `--inference-config`. Prompts routinely exceed `ARG_MAX`, and
  embedding JSON in a command line invites quoting bugs. Temp files MUST be
  deleted after the request, including on abort.
- R7.12 The model ID MUST come from `g:air_model`. There MUST be no default: Bedrock model IDs are account- and
  region-specific, and on-demand models often require a regional
  inference-profile prefix. A missing model MUST be reported by `check()`.
- R7.13 `maxTokens`, `temperature` and `topP` MUST be configurable, with
  `g:air_inference_config` as an escape hatch for any other
  `InferenceConfiguration` field. Only `maxTokens` MUST be sent by default:
  newer models reject `temperature` and `topP` as deprecated, so they MUST be
  omitted unless explicitly configured.
- R7.14 Response parsing MUST concatenate `output.message.content[].text` and
  MUST skip non-text blocks (`reasoningContent`, `toolUse`).
- R7.15 A `stopReason` of `max_tokens` MUST raise a visible warning: a truncated
  revision otherwise looks like a legitimate diff.
- R7.16 AWS CLI failures MUST display the provider's error text, without
  classifying error phrases or appending provider-specific advice.
- R7.17 Failures MUST report a single-line `echohl` error, with full stdout and
  stderr retrievable via `:AirLog`.

### 7.3 Execution

- R7.18 Requests SHOULD be async via `job_start`/`jobstart` so Vim is not
  blocked, falling back to a blocking `system()` call when jobs are unavailable.
- R7.19 An in-flight asynchronous request MUST be cancellable and MUST be
  bounded by `g:air_timeout`. The blocking fallback is bounded only by the
  backend's own timeouts: the AWS CLI's for Bedrock, and `--max-time` for
  OpenAI (R7.23).
- R7.20 Large inputs SHOULD be checked against a configurable size threshold and
  require confirmation before a request is made.

### 7.4 OpenAI API backend

- R7.21 The OpenAI backend MUST make exactly one Responses API call
  (`POST {base_url}/responses`) per revision through `curl`, with no agent
  loop, tool definitions or stored state (`"store": false`).
- R7.22 vim-air MUST NOT log, store or forward the API key; `check()` only
  tests that the variable is non-empty. `curl` MUST import it from the
  environment variable named by `g:air_openai_api_key_env` (default
  `OPENAI_API_KEY`) with `--variable` and expand it into the `Authorization`
  header with `--expand-header`, so it never appears in argv or a temp file.
  This requires curl 8.3+. `check()` MUST report an unset variable before
  spawning curl.
- R7.23 The request body MUST go over curl's stdin (`--data-binary @-`), not
  argv or a temp file. The system payload is sent as `instructions`, the user
  payload as `input`. curl MUST run with `-q`, so a `~/.curlrc` cannot change
  the output format, with `--fail-with-body`, so HTTP errors exit non-zero
  and still deliver the JSON error body, and with `--max-time` set from
  `g:air_timeout` (unless 0), since curl has no overall time limit of its own
  and the dispatcher's timer does not cover the blocking fallback.
- R7.24 The model MUST come from `g:air_openai_model`, and MUST NOT fall back to `g:air_model` (a Bedrock ID
  for most users). The effort MUST come from `g:air_openai_reasoning_effort`
  and is sent as `reasoning.effort`. The defaults MUST be `gpt-6-luna` at
  `low` effort; an explicit `''` effort MUST be omitted so the API default
  applies, and an explicit `''` model MUST be reported by `check()`. No
  configuration beyond the API key is required.
  `g:air_openai_max_output_tokens` MUST set `max_output_tokens` (default 8192).
  Arbitrary request-body parameters MUST NOT be supported.
  `g:air_openai_base_url`,
  `g:air_curl_cmd` and `g:air_curl_args` MUST be supported as pass-throughs.
- R7.25 The revision is the concatenated `output_text` of the `message` output
  items; reasoning items MUST be skipped. A `status` of `incomplete` MUST
  raise the R7.15 truncation warning, naming `max_output_tokens` when that is
  the reason. A `refusal` MUST fail with its text, and a `status` of `failed`
  MUST fail even without an error object. The error body MUST be found even
  when the sync transport has folded curl's stderr in front of it.
- R7.26 OpenAI and curl failures MUST display the provider or transport error
  text, without classifying error phrases or appending provider-specific advice.

## 8. Response handling

- R8.1 The plugin MUST strip surrounding code fences if the model adds them.
- R8.2 Trailing whitespace/newline normalization MUST match the original buffer
  so the diff shows real changes only.
- R8.2a Invisible leading junk MUST be scrubbed from the response: a byte-order
  mark anywhere, and zero-width or non-breaking blanks at the start. These
  render as a stray glyph, can leave a first line that only looks blank, and a
  BOM in front of a code fence defeats R8.1. U+200D MUST only be stripped at the
  start, since it is meaningful inside emoji sequences.
- R8.2b Indentation the model invents on the first line MUST be removed when the
  original region did not start indented; genuine indentation MUST be preserved
  when it did.
- R8.3 If the response is byte-identical to the source, MUST report "no changes
  proposed" and not open a split.
- R8.4 `diffopt` SHOULD be set per-session to patience hunks with word-level
  highlighting inside changed lines
  (`internal,filler,algorithm:patience,inline:word`, `iwhite` optional)
  without permanently mutating the user's global setting. Items the running
  Vim rejects (`inline:word` needs Vim 9.1.1243+) MUST be dropped rather than
  failing the session.

## 8a. Prompt entry

Vim has no built-in editable modal popup (`popup_create()` buffers are not
modifiable), so a scratch buffer is the mechanism for anything longer than one
line.

- R8a.1 `:Air <text>` MUST accept a literal one-shot prompt as an argument.
- R8a.2 `:Air <name>` MUST resolve a named prompt and submit immediately
  with no further input.
- R8a.3 Bare `:Air` MUST open a scratch **prompt buffer** for composition,
  giving full normal/insert mode editing, undo, registers, `gq`, spell check,
  and abbreviations.
- R8a.4 The prompt buffer MUST be `buftype=nofile bufhidden=wipe noswapfile`
  with a dedicated filetype so users can add their own mappings and settings.
- R8a.5 Submission and cancellation MUST use explicit buffer-local mappings so
  `<CR>` remains a literal newline. Defaults: `<CR>` (normal) submits, `q` or
  `<C-c>` cancels.
- R8a.6 The prompt buffer SHOULD be prefilled with the previous prompt.
- R8a.7 Prompt history SHOULD persist across sessions, recallable into the
  buffer with `<C-p>`/`<C-n>`.
- R8a.9 Prompts MUST also be sourceable from a register (`:Air @p`). Users can
  read prompt files into registers using Vim's `readfile()`.
- R8a.11 Prompt entry MUST behave identically in Vim and Neovim with no version
  gating.

## 9. Configuration surface

- Backend selection: `g:air_backend_name` (default `bedrock`)
- Bedrock: `g:air_model`, `g:air_aws_cmd`, `g:air_aws_profile`,
  `g:air_aws_region`, `g:air_aws_args`, `g:air_max_tokens`,
  `g:air_temperature`, `g:air_top_p`, `g:air_inference_config`
- OpenAI: `g:air_openai_model`, `g:air_openai_reasoning_effort`,
  `g:air_openai_max_output_tokens`, `g:air_openai_base_url`, `g:air_openai_api_key_env`,
  `g:air_curl_cmd`, `g:air_curl_args`
- Execution: `g:air_async`, `g:air_timeout`, `g:air_max_input_bytes`
- Prompting: `g:air_prompts`,
  `g:air_ft_prompts`, `g:air_system_prompt`, `g:air_prefill_last`,
  `g:air_history`, `g:air_history_file`, `g:air_history_size`
- Review UI: `g:air_diffopt`,
  `g:air_modifiable`, `g:air_default_scope`, `g:air_proposal_maps`
- Diagnostics: `g:air_log_size`
- Hooks: `g:Air_backend`, `g:Air_output_filter`
- R9.1 All settings MUST have sane defaults. The only required configuration is
  `g:air_model` for the Bedrock backend, because no Bedrock model ID is
  universally valid. The OpenAI backend needs only the API key in the
  environment.
- R9.2 MUST define no default mappings; `<Plug>` mappings MUST be provided.

## 10. Quality / distribution

- R10.1 `:help vim-air` documentation with examples for prose and code.
- R10.2 Tests via `vim -es` / vader-style harness for scope extraction, fence
  stripping, and diff session setup/teardown, with a mock provider.
- R10.3 The backend layer MUST be testable without network access: the
  dispatcher via a fake backend (R7.5) or the `g:Air_backend` hook (R7.7), and
  the Bedrock and OpenAI backends via stub `aws` and `curl` executables plus
  direct `parse()` unit tests.
- R10.4 Installable by copying the directory into `pack/*/start` or via any
  plugin manager; no build step.

## 11. Deferred to later versions

- Additional backends behind the §7.1 interface: Anthropic, Ollama, or a
  local HTTP endpoint. No dispatcher change should be needed.
- Bedrock streaming (`converse-stream`) for progressive proposals.
- Multi-turn refinement of a proposal ("now also fix the tense").
- Bedrock guardrails and cross-region inference profile helpers.

## 12. Open questions

- Should rejected/accepted hunks be logged for prompt iteration?
- Should there be an "explain this hunk" affordance, or does that violate the
  no-extra-UI goal?
- Multiple competing proposals (N-way diff) — worth it, or out of scope?
- Undo strategy: is native `do`/`dp` enough, or is a single-undo-block
  "accept all" command needed?

## 13. Implementation notes and deviations

Recorded during implementation; each is a deliberate departure from, or a
constraint discovered while satisfying, the requirements above.

- **R0.3 (variable prefix) — partial deviation.** Legacy Vim raises `E704` for a
  lowercase variable holding a `Funcref`, so the injectable hooks are named
  `g:Air_backend` and `g:Air_output_filter`. `air#hook()` also accepts the
  lowercase `g:air_*` form when the value is a function-name string, so the
  documented prefix still works for anyone who prefers it.
- **R7.9 (converse) — verified against the CLI surface.** `aws bedrock-runtime converse`
  exists with `--model-id`, `--messages`, `--system` and
  `--inference-config` in AWS CLI v2. It has not been run against a live
  Bedrock account from this environment; tests use a stub `aws` executable.
- **E746 constraint on backends.** Vim refuses to define an autoload-named
  function in a script whose path does not match, so a backend must be a real
  file at `autoload/air/backend/<name>.vim`. The test suite writes one to a temp
  runtimepath entry rather than defining the functions inline.
- **`exists('*air#foo#bar')` does not autoload.** The dispatcher explicitly
  `runtime!`s a backend file before checking the interface.
- **R7.13 (inference config) — omission is the safe default.** Sending
  `temperature: 0` for determinism failed against newer models with
  "`temperature` is deprecated for this model". Nothing but `maxTokens` is sent
  unless asked for. Provider error text is displayed without extra advice.
- **R7.18 (sync fallback) — streams cannot be separated.** `system()` folds
  stderr into stdout via `'shellredir'`, so on a non-zero exit the dispatcher
  passes the combined output to the backend as `stderr` too. Without this, AWS
  error messages were reduced to "exit status 254" whenever jobs were disabled.
- **R10.2 (tests) — harness details.** Vim's silent-ex mode (`-es`) suppresses
  `:echo`, and `writefile()` refuses `/dev/stderr` there, so results are
  appended to `$AIR_TEST_LOG` and printed by `test/run.sh`. Offline assertions, no
  network, no AWS and no OpenAI calls: the Bedrock and OpenAI backends are
  exercised through stub `aws` and `curl` scripts, and a fake backend covers
  the dispatcher interface.
- **§7.4 (OpenAI) — replaced the Codex CLI backend.** An earlier backend ran
  `codex exec` against a ChatGPT subscription. Its agent scaffolding (tool
  schemas, base instructions) added about 12k input tokens and a second of
  overhead to every request, and it offered no truncation signal, so it was
  dropped in favor of a single Responses API call.
- **§7.4 (OpenAI) — curl behaviour verified against curl 8.22.** Header
  expansion, the `--fail-with-body` exit status (22) with the JSON error body
  on stdout, and the unset-variable and unresolvable-host failures were checked
  against the live endpoint with a dummy key; tests use a stub `curl`. A
  successful response has not yet been checked against a live key.
- **R7.23 (stdin) — Vim's blocking fallback uses a temp file.** Vim's
  `system()` writes its `{input}` to a temporary file and redirects it to
  stdin, so with jobs unavailable the request body (never the API key) briefly
  exists on disk. Vim deletes it; the async transports and Neovim use a pipe.
- **R4.9 (window sizes) — restored after the window is gone.** `BufWipeout`
  fires while the closing proposal window still counts, and `winrestcmd()`
  addresses windows by number, so sizes are replayed only once the tab page is
  back to its pre-split window count: immediately by `:AirClose`, and on the
  next timer tick after a direct `:quit` or `:bwipeout`.
- **R8.4 (diffopt) — items are applied one by one.** Vim rejects the whole
  `diffopt` assignment (`E474`) if any item is unknown, and Vim 8.0 predates
  `internal` and `algorithm:`, so each item is tried in turn and kept only if
  accepted.
- **Fixed workflow.** The input UI, horizontal split, per-request model and
  prompt-file options, arbitrary OpenAI body parameters, and provider error
  advice were removed. Both Bedrock and OpenAI remain supported. Legacy UI and
  body-parameter settings are ignored; removed command options are errors.
