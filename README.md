# vim-air — Vim AI Review

Submit an AI prompt to revise a buffer, then review the proposal in Vim's
**native diff mode**.

```
:Air tighten this section

+---------------------------+---------------------------+
| your buffer               | proposed revision         |
| (diff mode)               | (scratch, nomodifiable)   |
+---------------------------+---------------------------+

]c  next change    do  take the proposal
[c  previous       dp  keep yours          :AirClose
```

No floating windows, no virtual text, no bespoke review UI. The review
interface is the one you already know.

## Why

Most AI editor plugins assume you are writing code, so they optimize for patch
application or inline replacement — and most are Neovim-only. For prose the
right interaction is closer to a copy editor marking up a manuscript, and Vim's
diff mode is already a mature tool for exactly that: word-level changes are
visible, hunks are accepted individually, the original is always on screen, and
undo stays simple.

vim-air works in classic Vim 8, is pure Vimscript, and is built for prose as
much as for code.

## Requirements

- Vim 8.0+ or Neovim
- AWS CLI v2 on `$PATH`, with working credentials
- Amazon Bedrock model access in your account and region

vim-air never handles credentials. The AWS CLI resolves them however you
already do — environment variables, a config profile, SSO, or an instance role.

```vim
" the only required setting: Bedrock model IDs are account/region specific
let g:air_model = 'us.anthropic.claude-sonnet-5'
let g:air_aws_region = 'us-east-1'   " or rely on your AWS config
```

Requests go out as `aws bedrock-runtime converse`, which has one request shape
for every Bedrock model.

## Install

Any plugin manager, or just drop it in a package directory:

```sh
git clone https://github.com/you/vim-air ~/.vim/pack/plugins/start/vim-air
vim -c 'helptags ~/.vim/pack/plugins/start/vim-air/doc' -c q
```

No build step.

## Use

```vim
:Air                        " compose the prompt in a scratch buffer
:Air tighten                " a named prompt
:Air make this less breathless
:'<,'>Air fix the grammar   " visual selection
:AirParagraph cut this in half
:AirSection -model=anthropic/claude-sonnet-4-5 rewrite the intro
:Air @p                     " prompt from register p
:Air -f prompts/copyedit.md
```

Then `]c` `[c` `do` `dp`, and `:AirClose` when you are done. `:AirAbort`
cancels a request in flight; `:AirLog` shows what was sent and returned.

### Scopes

| Scope       | What it sends                                              |
| ----------- | ---------------------------------------------------------- |
| `buffer`    | the whole buffer (default)                                 |
| `range`     | the `[range]` or visual selection                          |
| `paragraph` | the non-blank block around the cursor                      |
| `section`   | a Markdown heading through the next same-or-higher heading |
| `motion`    | whatever an operator covers, via `<Plug>AirMotion`         |

Partial scopes still diff against the **whole** buffer: the model sees the
surrounding text as context, revises only the marked region, and the result is
spliced back in. Hunk-by-hunk merging works normally.

### The prompt buffer

A bare `:Air` opens a scratch buffer, because Vim has no editable modal popup
(`popup_create()` buffers are not modifiable). You get real normal and insert
mode, undo, registers, `gq`, spell check and abbreviations while writing the
prompt.

```
# air: describe the revision you want.
# <CR> submit   q cancel   <C-p>/<C-n> prompt history
# lines starting with # are ignored
# scope: paragraph
Tighten. Remove repetition. Preserve my voice.
```

`<CR>` submits from normal mode only, so it stays a newline while you type.
Edit the `# scope:` line to retarget without starting over. Prompt history
persists across sessions.

Prefer a one-liner? `let g:air_prompt_ui = 'input'`.

### Named prompts

Ships with `tighten`, `grammar`, `passive`, `cliches`, `claims`, `simplify`,
`structure` for prose and `docs`, `modernize`, `refactor` for code. Override or
add your own:

```vim
let g:air_prompts = {
  \ 'mcphee': 'Rewrite in the voice of John McPhee. Keep every fact.',
  \ }
let g:air_ft_prompts = {
  \ 'go': {'docs': 'Add godoc comments to exported symbols.'},
  \ }
```

### Mappings

None by default:

```vim
nmap <Leader>ar <Plug>AirRevise
xmap <Leader>ar <Plug>AirRevise
nmap <Leader>ap <Plug>AirParagraph
nmap <Leader>am <Plug>AirMotion     " <Leader>amip, <Leader>amaf, ...
```

## Configuration

`g:air_model` is the only thing you must set. Common knobs:

```vim
let g:air_aws_profile = 'work'
let g:air_max_tokens = 16384
" temperature/topP are omitted by default — newer models reject them
let g:air_split = 'horizontal'   " default 'vertical'
let g:air_modifiable = 1         " edit the proposal before merging
let g:air_timeout = 180
```

See `:help air-config` for the full list.

## Backends

Built for several, ships one (`bedrock`). A backend is one file on your
`runtimepath` at `autoload/air/backend/<name>.vim` implementing three
functions:

```vim
air#backend#foo#check()                  " '' if usable, else why not
air#backend#foo#request(payload, opts)   " {'argv': [...], 'stdin': ...}
air#backend#foo#parse(result)            " {'ok', 'text', 'error', 'warning'}
```

The dispatcher owns argv execution, async and sync transports, timeouts,
aborting, temp-file cleanup and logging, so a backend is pure provider logic.
Select one with `let g:air_backend_name = 'foo'`. See
`:help air-backend-interface`.

## Tests

```sh
make test
```

No network and no AWS calls: the dispatcher is tested against a fake backend,
the Bedrock backend against a stub `aws` executable plus direct `parse()` unit
tests, and `g:Air_backend` bypasses the layer entirely.

## Linting

[pre-commit](https://pre-commit.com) runs `vint` on the Vim script, `shellcheck`
on the shell, `prettier` on Markdown/YAML, `typos` on everything, and
`committed` on the commit message.

```sh
make hooks         # install the pre-commit and commit-msg hooks
make lint          # run every hook over the whole tree
make update-hooks  # bump pinned hook versions
```

## Design notes

- `REQUIREMENTS.md` holds the numbered requirements the code is written against.
- Prompts reach Bedrock as `file://` temp files, not argv: prompts routinely
  exceed `ARG_MAX` and quoting JSON on a command line is a bug farm.
- Nothing writes to your buffer except your own `do`/`dp`.
- Only `maxTokens` is sent by default. Newer Bedrock models reject
  `temperature` and `topP` with a `ValidationException`, so they are omitted
  unless you explicitly set them.
- A `stopReason` of `max_tokens` raises a loud warning: a truncated revision
  otherwise looks like a perfectly good diff.

## License

MIT
