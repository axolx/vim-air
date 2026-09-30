" vim-air — prompts: named presets, composition, prompt buffer, history (§6, §8a)

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

" R6.3 — small default set: prose first, code second.
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
  let instruction = substitute(instruction, '{filetype}', a:req.filetype, 'g')
  let instruction = substitute(instruction, '{filename}', a:req.filename, 'g')

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
function! air#prompt#open(request) abort
  if air#get('prompt_ui', 'buffer') ==# 'input'
    return s:open_input(a:request)
  endif

  let comment = air#get('prompt_comment', '#')
  let height = air#get('prompt_height', 10)

  execute 'botright' height 'new'
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

  " R8a.6 — prefill with the previous prompt, unless the request already
  " carries prompt text.
  let prefill = !empty(a:request.prompt)
        \ ? a:request.prompt
        \ : air#get('prefill_last', 1) ? air#prompt#last() : ''

  let header = [
        \ comment . ' air: describe the revision you want.',
        \ comment . ' <CR> submit   q cancel   <C-p>/<C-n> prompt history',
        \ comment . ' lines starting with ' . comment . ' are ignored',
        \ comment . ' scope: ' . a:request.scope,
        \ ]
  call setline(1, header + split(prefill, "\n", 1))

  call cursor(len(header) + 1, 1)
  if empty(prefill)
    startinsert
  endif
endfunction

" R8a.10 — single-line cmdline fallback with named-prompt completion.
function! s:open_input(request) abort
  let text = input('air (' . a:request.scope . '): ',
        \ a:request.prompt, 'customlist,air#complete')
  redraw
  if empty(substitute(text, '\_s', '', 'g'))
    call air#info('cancelled')
    return
  endif
  let req = a:request
  let req.prompt = text
  call air#send(req)
endfunction

" R8a.5 / R8a.8 — strip comments, honour an edited "# scope:" directive.
function! air#prompt#submit() abort
  if !exists('b:air_request')
    call air#error('not an air prompt buffer')
    return
  endif

  let comment = air#get('prompt_comment', '#')
  let req = b:air_request
  let lines = getline(1, '$')

  let scope = req.scope
  for l in lines
    let m = matchstr(l, '^' . comment . '\s*scope:\s*\zs\S\+')
    if !empty(m)
      let scope = m
    endif
  endfor

  let body = filter(copy(lines), 'v:val !~# "^" . comment')
  let prompt = substitute(join(body, "\n"), '^\_s*\|\_s*$', '', 'g')

  if empty(prompt)
    call air#error('empty prompt')
    return
  endif

  let srcbuf = req.srcbuf
  close

  " Re-resolve the scope if the user edited the directive.
  if scope !=# req.scope
    let win = bufwinnr(srcbuf)
    if win == -1
      call air#error('source buffer is no longer visible')
      return
    endif
    execute win . 'wincmd w'
    try
      let region = air#scope#resolve(scope, 0, 0)
    catch /^air:/
      call air#error(substitute(v:exception, '^air:\s*', '', ''))
      return
    endtry
    let req.scope = region.name
    let req.start = region.start
    let req.end = region.end
    let req.all_lines = getbufline(srcbuf, 1, '$')
  endif

  let req.prompt = prompt
  call air#send(req)
endfunction

function! air#prompt#cancel() abort
  close
  call air#info('cancelled')
endfunction

" ------------------------------------------------------------- history ------

function! s:history_file() abort
  let default = (has('nvim') ? stdpath('cache') : expand('~/.cache/vim'))
        \ . '/air-history.jsonl'
  return expand(air#get('history_file', default))
endfunction

" R8a.7 — persist prompts across sessions.
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

  let comment = air#get('prompt_comment', '#')
  let header = filter(getline(1, '$'), 'v:val =~# "^" . comment')
  silent %delete _
  call setline(1, header + split(hist[idx], "\n", 1))
  call cursor(len(header) + 1, 1)
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
