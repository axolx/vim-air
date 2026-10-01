" vim-air — main orchestration (autoload namespace air#, R0.4)

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

" ---------------------------------------------------------------- config ----

" R9.1 — every setting has a default. The only required configuration is
" g:air_model, since Bedrock model IDs are account- and region-specific.
" REQ 14.4
function! air#get(name, default) abort
  return get(g:, 'air_' . a:name, a:default)
endfunction

" Legacy Vim refuses `let g:air_backend = function(...)` with E704: a variable
" holding a Funcref must start with a capital. So overridable hooks are looked
" up as either g:Air_<name> (a Funcref) or g:air_<name> (a function-name
" string). Returns v:null when unset.
" REQ 14.5
function! air#hook(name) abort
  if has_key(g:, 'Air_' . a:name)
    return get(g:, 'Air_' . a:name)
  endif
  if has_key(g:, 'air_' . a:name)
    let val = get(g:, 'air_' . a:name)
    return type(val) == type('') ? function(val) : val
  endif
  return v:null
endfunction

" REQ 15.1
function! air#error(msg) abort
  call air#log#add('ERROR: ' . a:msg)
  echohl ErrorMsg
  echomsg 'air: ' . substitute(a:msg, '\_s\+', ' ', 'g')
  echohl None
endfunction

" A message wider than the command line wraps into a hit-enter prompt, so
" shorten it in the middle as 'shortmess' "T" would. :AirLog keeps it whole.
function! s:fit(msg) abort
  let room = (exists('v:echospace') ? v:echospace : &columns - 12) - 1
  if strdisplaywidth(a:msg) <= room || room < 10
    return a:msg
  endif
  let chars = split(a:msg, '\zs')
  let half = (room - 3) / 2
  return join(chars[: half - 1], '') . '...'
        \ . join(chars[len(chars) - (room - 3 - half) :], '')
endfunction

function! air#warn(msg) abort
  call air#log#add('WARN: ' . a:msg)
  echohl WarningMsg
  echomsg s:fit('air: ' . a:msg)
  echohl None
endfunction

function! air#info(msg) abort
  call air#log#add('info: ' . a:msg)
  echohl None
  echomsg s:fit('air: ' . a:msg)
endfunction

" ------------------------------------------------------------ arg parsing ----

" Accepts literal and named prompts, @register, and -scope=NAME.
" REQ 1.3, REQ 1.4, REQ 1.5, REQ 1.8, REQ 1.11
function! air#parse_args(args) abort
  let out = {'prompt': '', 'scope': '', 'source': 'literal'}
  let rest = a:args

  while rest =~# '^\s*-'
    let rest = substitute(rest, '^\s*', '', '')
    let tok = matchstr(rest, '^\S\+')
    if tok =~# '^-scope='
      let out.scope = tok[7:]
    else
      throw 'air: unknown option ' . tok
    endif
    let rest = substitute(rest, '^\S\+\s*', '', '')
  endwhile

  let rest = substitute(rest, '^\s*\|\s*$', '', 'g')

  if rest =~# '^@.$'
    let out.prompt = substitute(getreg(rest[1]), '\n\+$', '', '')
    let out.source = 'register'
  elseif !empty(rest) && has_key(air#prompt#named(), rest)
    let out.prompt = air#prompt#named()[rest]
    let out.source = 'named'
    let out.name = rest
  else
    let out.prompt = rest
  endif

  return out
endfunction

" REQ 1.9
function! air#complete(arglead, cmdline, cursorpos) abort
  let cands = keys(air#prompt#named())
        \ + ['-scope=buffer', '-scope=range', '-scope=paragraph',
        \    '-scope=section', '-scope=motion']
  return sort(filter(cands, 'stridx(v:val, a:arglead) == 0'))
endfunction

" --------------------------------------------------------------- entry ------

" R4.1 — build the request, then either submit or open the prompt buffer.
" REQ 1.1, REQ 1.2, REQ 2.1
function! air#revise(scope_hint, line1, line2, args) abort
  try
    let parsed = air#parse_args(a:args)
  catch /^air:/
    call air#error(substitute(v:exception, '^air:\s*', '', ''))
    return
  endtry

  let scope = !empty(parsed.scope) ? parsed.scope
        \ : (!empty(a:scope_hint) ? a:scope_hint : air#get('default_scope', 'buffer'))

  try
    let region = air#scope#resolve(scope, a:line1, a:line2)
  catch /^air:/
    call air#error(substitute(v:exception, '^air:\s*', '', ''))
    return
  endtry

  let request = air#request(region, parsed)

  " R8a.3 — bare :Air (no prompt text) opens the prompt buffer.
  if empty(substitute(request.prompt, '\_s', '', 'g'))
    call air#prompt#open(request)
  else
    call air#send(request)
  endif
endfunction

function! air#request(region, parsed) abort
  let bufnr = bufnr('%')
  return {
        \ 'srcbuf':    bufnr,
        \ 'scope':     a:region.name,
        \ 'start':     a:region.start,
        \ 'end':       a:region.end,
        \ 'all_lines': getbufline(bufnr, 1, '$'),
        \ 'prompt':    a:parsed.prompt,
        \ 'changedtick': getbufvar(bufnr, 'changedtick'),
        \ 'filetype':  getbufvar(bufnr, '&filetype'),
        \ 'filename':  expand('%:t'),
        \ }
endfunction

" R5.5 — operator form, uses the '[ '] marks set by g@.
" REQ 2.8
function! air#motion(type) abort
  call air#revise('motion', line("'["), line("']"), '')
endfunction

" --------------------------------------------------------------- sending ----

" REQ 8.1, REQ 10.7, REQ 10.9
function! air#send(request) abort
  let req = a:request
  let req.target_lines = req.all_lines[req.start - 1 : req.end - 1]

  " R7.20 — confirm oversized input rather than silently spending tokens.
  let bytes = strlen(join(req.all_lines, "\n"))
  let limit = air#get('max_input_bytes', 100000)
  if bytes > limit
    let msg = printf('input is %d bytes (limit %d). Send anyway?', bytes, limit)
    if confirm(msg, "&Yes\n&No", 2) != 1
      call air#info('cancelled')
      return
    endif
  endif

  let payload = air#prompt#compose(req)
  call air#log#add('--- request (backend=' . air#backend#name()
        \ . ' scope=' . req.scope
        \ . ' lines ' . req.start . '-' . req.end . ") ---\n"
        \ . payload.system . "\n\n" . payload.user)

  " Messages stacked without a redraw between them (the confirm() above, then
  " this one and the response's) end in a hit-enter prompt; each redraw
  " clears the message area so only the latest line shows.
  redraw
  call air#info('revising ' . req.scope . ' ('
        \ . (req.end - req.start + 1) . ' lines)…')

  " Only prompts that were actually sent are worth recalling.
  if air#backend#run(payload, {}, function('s:on_response', [req]))
    call air#prompt#remember(req.prompt)
  endif
endfunction

" REQ 4.8
function! s:on_response(req, result) abort
  call air#log#add('--- response (ok=' . a:result.ok . ") ---\n"
        \ . get(a:result, 'raw', ''))
  redraw

  if !a:result.ok
    call air#error(a:result.error . ' (see :AirLog)')
    return
  endif

  let lines = air#text#clean(a:result.text, a:req.target_lines,
        \ getbufvar(a:req.srcbuf, '&fileformat'))

  if empty(lines)
    call air#error('backend returned no usable text (see :AirLog)')
    return
  endif

  call air#diff#open(a:req, lines)

  " REQ 11.12, REQ 12.17 — a truncation warning outranks "proposal ready".
  let warning = get(a:result, 'warning', '')
  if !empty(warning)
    redraw
    call air#warn(warning)
  endif
endfunction

function! air#abort() abort
  if air#backend#abort()
    call air#info('request aborted')
  else
    call air#info('no request in flight')
  endif
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
