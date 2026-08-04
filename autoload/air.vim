" vim-air — main orchestration (autoload namespace air#, R0.4)

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

" ---------------------------------------------------------------- config ----

" R9.1 — every setting has a default. The only required configuration is
" g:air_model, since Bedrock model IDs are account- and region-specific.
function! air#get(name, default) abort
  return get(b:, 'air_' . a:name, get(g:, 'air_' . a:name, a:default))
endfunction

" Legacy Vim refuses `let g:air_backend = function(...)` with E704: a variable
" holding a Funcref must start with a capital. So overridable hooks are looked
" up as either g:Air_<name> (a Funcref) or g:air_<name> (a function-name
" string). Returns v:null when unset.
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

function! air#error(msg) abort
  call air#log#add('ERROR: ' . a:msg)
  echohl ErrorMsg
  echomsg 'air: ' . a:msg
  echohl None
endfunction

function! air#warn(msg) abort
  call air#log#add('WARN: ' . a:msg)
  echohl WarningMsg
  echomsg 'air: ' . a:msg
  echohl None
endfunction

function! air#info(msg) abort
  call air#log#add('info: ' . a:msg)
  echohl None
  echomsg 'air: ' . a:msg
endfunction

" ------------------------------------------------------------ arg parsing ----

" Accepts: literal prompt, named prompt, @register (R8a.9), -f PATH (R8a.9),
" -scope=NAME, -model=NAME.
function! air#parse_args(args) abort
  let out = {'prompt': '', 'scope': '', 'model': '', 'source': 'literal'}
  let rest = a:args

  while rest =~# '^\s*-'
    let rest = substitute(rest, '^\s*', '', '')
    let tok = matchstr(rest, '^\S\+')
    if tok =~# '^-scope='
      let out.scope = tok[7:]
    elseif tok =~# '^-model=' || tok =~# '^-m='
      let out.model = matchstr(tok, '=\zs.*')
    elseif tok ==# '-f' || tok ==# '-file'
      let rest = substitute(rest, '^\S\+\s*', '', '')
      let path = matchstr(rest, '^\S\+')
      if empty(path)
        throw 'air: -f requires a path'
      endif
      let out.prompt = s:read_file(path)
      let out.source = 'file'
      let tok = path
    elseif tok =~# '^-f=' || tok =~# '^-file='
      let out.prompt = s:read_file(matchstr(tok, '=\zs.*'))
      let out.source = 'file'
    else
      throw 'air: unknown option ' . tok
    endif
    let rest = substitute(rest, '^\S\+\s*', '', '')
  endwhile

  let rest = substitute(rest, '^\s*\|\s*$', '', 'g')

  if out.source ==# 'file'
    return out
  endif

  if rest =~# '^@.$'
    let out.prompt = s:register_text(rest[1])
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

function! s:read_file(path) abort
  let path = expand(a:path)
  if !filereadable(path)
    throw 'air: cannot read prompt file ' . path
  endif
  return join(readfile(path), "\n")
endfunction

function! s:register_text(reg) abort
  let val = getreg(a:reg)
  if empty(val)
    throw 'air: register @' . a:reg . ' is empty'
  endif
  return substitute(val, '\n\+$', '', '')
endfunction

function! air#complete(arglead, cmdline, cursorpos) abort
  let cands = keys(air#prompt#named())
        \ + ['-scope=buffer', '-scope=range', '-scope=paragraph',
        \    '-scope=section', '-scope=motion', '-f', '-model=']
  return sort(filter(cands, 'stridx(v:val, a:arglead) == 0'))
endfunction

" --------------------------------------------------------------- entry ------

" R4.1 — build the request, then either submit or open the prompt buffer.
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
        \ 'model':     a:parsed.model,
        \ 'filetype':  getbufvar(bufnr, '&filetype'),
        \ 'filename':  expand('%:t'),
        \ }
endfunction

" R5.5 — operator form, uses the '[ '] marks set by g@.
function! air#motion(type) abort
  call air#revise('motion', line("'["), line("']"), '')
endfunction

" --------------------------------------------------------------- sending ----

function! air#send(request) abort
  let req = a:request
  let req.target_lines = req.all_lines[req.start - 1 : req.end - 1]

  " R7.10 — confirm oversized input rather than silently spending tokens.
  let bytes = strlen(join(req.all_lines, "\n"))
  let limit = air#get('max_input_bytes', 100000)
  if bytes > limit
    let msg = printf('input is %d bytes (limit %d). Send anyway?', bytes, limit)
    if confirm(msg, "&Yes\n&No", 2) != 1
      call air#info('cancelled')
      return
    endif
  endif

  call air#prompt#remember(req.prompt)
  let payload = air#prompt#compose(req)
  call air#log#add('--- request (backend=' . air#backend#name()
        \ . ' scope=' . req.scope
        \ . ' lines ' . req.start . '-' . req.end . ") ---\n"
        \ . payload.system . "\n\n" . payload.user)

  let s:request = req
  call air#info('revising ' . req.scope . ' ('
        \ . (req.end - req.start + 1) . ' lines)…')

  call air#backend#run(payload, {'model': req.model},
        \ function('s:on_response', [req]))
endfunction

function! s:on_response(req, result) abort
  call air#log#add('--- response (ok=' . a:result.ok . ") ---\n"
        \ . get(a:result, 'raw', ''))

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
