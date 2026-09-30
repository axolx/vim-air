" vim-air — prompts: named presets, composition, prompt buffer, history (§6, §8a)

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

" R6.3 — small default set: prose first, code second.
" REQ 5.2, REQ 5.3
let s:defaults = {
      \ 'tighten':    'Tighten the prose. Remove repetition and filler. Preserve my voice and meaning.',
      \ 'grammar':    'Copy edit for grammar, spelling and punctuation only. Do not change tone, voice, word choice or structure.',
      \ 'passive':    'Reduce passive voice where an active construction reads better. Change nothing else.',
      \ 'cliches':    'Remove clichés and stock phrases. Replace them with plain, specific language.',
      \ 'claims':     'Find unsupported or overstated claims. Soften or qualify them. Leave everything else untouched.',
      \ 'simplify':   'Simplify. Prefer shorter sentences and concrete words. Keep all substance.',
      \ 'structure':  'Improve paragraph order and transitions. Keep the wording as close to the original as possible.',
      \ 'docs':       'Add or improve doc comments. Do not change behaviour or reformat unrelated code.',
      \ 'modernize':  'Modernize this code to current idiomatic style for its language. Preserve behaviour exactly.',
      \ 'refactor':   'Simplify this code without changing behaviour. Keep the public interface intact.',
      \ }

" R6.1 / R6.6 — user prompts override defaults; filetype prompts override both.
" REQ 5.1, REQ 5.4, REQ 5.5
function! air#prompt#named() abort
  let named = copy(s:defaults)
  call extend(named, air#get('prompts', {}))
  let ft = &filetype
  let ftmap = air#get('ft_prompts', {})
  if !empty(ft) && has_key(ftmap, ft)
    call extend(named, ftmap[ft])
  endif
  return named
endfunction

" ----------------------------------------------------------- composition ----

" R6.4 — the "return only the text" instruction is load-bearing: chat-tuned
" models otherwise narrate, apologize, or wrap output in fences.
" REQ 6.2, REQ 6.3, REQ 6.4
function! air#prompt#system() abort
  return air#get('system_prompt', join([
        \ 'You are a careful reviser of text and code.',
        \ 'You will be given a document and an instruction.',
        \ 'Return ONLY the revised text.',
        \ 'Do not explain, comment, summarize, or describe your changes.',
        \ 'Do not wrap the output in code fences.',
        \ 'Do not add or remove trailing blank lines.',
        \ 'Preserve the author''s voice, formatting conventions and language',
        \ 'unless the instruction explicitly asks otherwise.',
        \ 'Make only the changes the instruction asks for.',
        \ ], "\n"))
endfunction

" R6.5 — placeholders for filetype/filename; region markers for partial scopes.
" Returns {'system': ..., 'user': ...} — backends map that onto their own
" request shape (Bedrock converse takes system and messages separately).
" REQ 6.1, REQ 6.5, REQ 6.6, REQ 6.7
function! air#prompt#compose(req) abort
  let parts = []

  let meta = []
  if !empty(a:req.filetype)
    call add(meta, 'Filetype: ' . a:req.filetype)
  endif
  if !empty(a:req.filename)
    call add(meta, 'Filename: ' . a:req.filename)
  endif
  if !empty(meta)
    call add(parts, join(meta, "\n"))
  endif

  let instruction = a:req.prompt
  " Escaped: '&', '~' and '\' are special in a substitute() replacement.
  let instruction = substitute(instruction, '{filetype}',
        \ escape(a:req.filetype, '&~\'), 'g')
  let instruction = substitute(instruction, '{filename}',
        \ escape(a:req.filename, '&~\'), 'g')

  let whole = a:req.start == 1 && a:req.end == len(a:req.all_lines)

  if whole
    call add(parts, "INSTRUCTION:\n" . instruction)
    call add(parts, "DOCUMENT:\n" . join(a:req.all_lines, "\n"))
    call add(parts, 'Return the full revised document and nothing else.')
  else
    " R5.2 — the model sees the whole document for context but revises only the
    " marked region, so the diff can still be presented in full-buffer context.
    call add(parts, "INSTRUCTION:\n" . instruction)
    call add(parts, "DOCUMENT (for context):\n" . air#prompt#mark_region(a:req))
    call add(parts, join([
          \ 'Revise ONLY the lines between the BEGIN REGION and END REGION',
          \ 'markers. Return the revised region only, without the markers and',
          \ 'without any surrounding text.',
          \ ], "\n"))
  endif

  return {'system': air#prompt#system(), 'user': join(parts, "\n\n")}
endfunction

function! air#prompt#mark_region(req) abort
  let before = a:req.start > 1 ? a:req.all_lines[0 : a:req.start - 2] : []
  let region = a:req.all_lines[a:req.start - 1 : a:req.end - 1]
  let after  = a:req.end < len(a:req.all_lines) ? a:req.all_lines[a:req.end :] : []
  return join(before + ['<<< BEGIN REGION >>>'] + region
        \ + ['<<< END REGION >>>'] + after, "\n")
endfunction

" -------------------------------------------------------- prompt buffer -----

" R8a.3 — a scratch buffer, because Vim has no editable modal popup:
" popup_create() buffers are not modifiable.
" REQ 7.1, REQ 7.2, REQ 7.7
function! air#prompt#open(request) abort
  botright 10new
  let bufname = 'air://prompt'
  if bufexists(bufname)
    execute 'silent! bwipeout!' bufnr(bufname)
  endif
  execute 'silent file' fnameescape(bufname)

  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal winfixheight nonumber norelativenumber
  setlocal filetype=air

  let b:air_request = a:request
  let b:air_history_idx = -1

  " R8a.6 — prefill with the previous prompt.
  if air#get('prefill_last', 1)
    call setline(1, split(air#prompt#last(), "\n", 1))
  endif
endfunction

" R8a.5 — the whole buffer is the prompt.
" REQ 7.11
function! air#prompt#submit() abort
  if !exists('b:air_request')
    call air#error('not an air prompt buffer')
    return
  endif

  let req = b:air_request
  let prompt = substitute(join(getline(1, '$'), "\n"), '^\_s*\|\_s*$', '', 'g')

  if empty(prompt)
    call air#error('empty prompt')
    return
  endif

  close
  let req.prompt = prompt
  call air#send(req)
endfunction

" REQ 7.6
function! air#prompt#cancel() abort
  close
  call air#info('cancelled')
endfunction

" ------------------------------------------------------------- history ------

" REQ 8.1, REQ 13.2
function! s:history_file() abort
  let default = (has('nvim') ? stdpath('cache') : expand('~/.cache/vim'))
        \ . '/air-history.jsonl'
  return expand(air#get('history_file', default))
endfunction

" R8a.7 — persist prompts across sessions.
" REQ 8.1, REQ 8.2, REQ 8.3, REQ 8.5
function! air#prompt#remember(prompt) abort
  if !air#get('history', 1) || empty(a:prompt)
    return
  endif
  let file = s:history_file()
  let dir = fnamemodify(file, ':h')
  if !isdirectory(dir)
    call mkdir(dir, 'p')
  endif
  let entries = air#prompt#history()
  call filter(entries, 'v:val !=# a:prompt')
  call add(entries, a:prompt)
  let max = air#get('history_size', 200)
  if len(entries) > max
    let entries = entries[-max :]
  endif
  call writefile(map(copy(entries), 'json_encode(v:val)'), file)
endfunction

function! air#prompt#history() abort
  let file = s:history_file()
  if !filereadable(file)
    return []
  endif
  let out = []
  for line in readfile(file)
    if empty(line)
      continue
    endif
    try
      call add(out, json_decode(line))
    catch
    endtry
  endfor
  return out
endfunction

function! air#prompt#last() abort
  let h = air#prompt#history()
  return empty(h) ? '' : h[-1]
endfunction

" <C-p>/<C-n> inside the prompt buffer.
" REQ 8.4
function! air#prompt#recall(delta) abort
  let hist = air#prompt#history()
  if empty(hist)
    call air#info('no prompt history')
    return
  endif

  let idx = get(b:, 'air_history_idx', -1)
  if idx == -1
    let idx = a:delta < 0 ? len(hist) - 1 : 0
  else
    let idx += a:delta
  endif
  let idx = max([0, min([len(hist) - 1, idx])])
  let b:air_history_idx = idx

  silent %delete _
  call setline(1, split(hist[idx], "\n", 1))
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
