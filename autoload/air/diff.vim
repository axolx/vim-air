" vim-air — diff session management (§4, R8.3, R8.4)

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

" One review across the editor.
let s:session = {}

let s:winopts = ['wrap', 'foldmethod', 'foldcolumn', 'foldenable',
      \ 'foldlevel', 'scrollbind', 'cursorbind', 'diff']

function! s:save_winopts() abort
  let saved = {}
  for opt in s:winopts
    let saved[opt] = getwinvar(0, '&' . opt)
  endfor
  return saved
endfunction

function! s:restore_winopts(saved) abort
  for [opt, val] in items(a:saved)
    call setwinvar(0, '&' . opt, val)
  endfor
endfunction

" R4.9 — put window sizes back as they were before the split. Opening and
" closing the proposal re-equalizes windows under 'equalalways', which loses
" any sizes the user set. winrestcmd() addresses windows by number, so it is
" only replayed when the tab page has the same window count as when saved.
" Extra arguments (a timer ID) are ignored.
" REQ 3.11
function! s:restore_layout(session, ...) abort
  if get(a:session, 'layout_restored', 0)
    return
  endif
  let current = win_getid()
  if !win_gotoid(a:session.srcwin)
    return
  endif
  try
    if winnr('$') == a:session.wincount
      execute a:session.winrest
      let a:session.layout_restored = 1
    endif
  finally
    call win_gotoid(current)
  endtry
endfunction

" R8.4 — apply a 'diffopt' value, keeping every item this Vim accepts.
" "inline:word" needs Vim 9.1.1243+, and Vim 8.0 predates "internal" and
" "algorithm:", so an item the build rejects is dropped instead of failing
" the whole setting.
" REQ 3.14
function! s:set_diffopt(want) abort
  let accepted = []
  for item in split(a:want, ',')
    try
      let &diffopt = join(accepted + [item], ',')
      call add(accepted, item)
    catch /^Vim\%((\a\+)\)\=:E474:/
    endtry
  endfor
  let &diffopt = join(accepted, ',')
endfunction

" R4.3/R4.4 — the response lands in a scratch buffer beside the original.
" REQ 3.1, REQ 3.2, REQ 3.4, REQ 3.5, REQ 3.6, REQ 3.7, REQ 3.8,
" REQ 3.13, REQ 3.16, REQ 3.17, REQ 3.18
function! air#diff#open(req, lines) abort
  " REQ 3.21
  if getbufvar(a:req.srcbuf, 'changedtick') != a:req.changedtick
    call air#error('source buffer changed; run :Air again')
    return
  endif

  let proposal_lines = air#text#splice(a:req.all_lines,
        \ a:req.start, a:req.end, a:lines)

  " R8.3 — identical output is not worth a split.
  if proposal_lines ==# a:req.all_lines
    call air#info('no changes proposed')
    return
  endif

  let srcwin = bufwinnr(a:req.srcbuf)
  if srcwin == -1
    call air#error('source buffer is no longer visible')
    return
  endif

  " Replacing a review restores its options before saving the next session.
  let source = win_getid(srcwin)
  call air#diff#close()
  if !win_gotoid(source) || bufnr('%') != a:req.srcbuf
    call air#error('source buffer is no longer visible')
    return
  endif
  let session = {
        \ 'srcbuf': a:req.srcbuf,
        \ 'srcwin': source,
        \ 'srcwin_opts': s:save_winopts(),
        \ 'diffopt': &diffopt,
        \ 'scope': a:req.scope,
        \ 'winrest': winrestcmd(),
        \ 'wincount': winnr('$'),
        \ }

  " R8.4 — patience hunks and word-level highlighting within changed lines,
  " restored on close.
  let want = air#get('diffopt',
        \ 'internal,filler,algorithm:patience,inline:word')
  if !empty(want)
    call s:set_diffopt(want)
  endif

  diffthis

  let ft = getbufvar(a:req.srcbuf, '&filetype')
  let ff = getbufvar(a:req.srcbuf, '&fileformat')
  let fe = getbufvar(a:req.srcbuf, '&fileencoding')

  vertical new

  let name = 'air://proposal/' . a:req.srcbuf
  if bufexists(name)
    execute 'silent! bwipeout!' bufnr(name)
  endif
  execute 'silent file' fnameescape(name)

  " R4.6 / R4.5 — scratch, but inheriting the options diffing depends on.
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  let &l:filetype = ft
  let &l:fileformat = ff
  let &l:fileencoding = fe

  silent %delete _
  call setline(1, proposal_lines)

  " R0.5 — the proposal buffer keeps the source filetype, so it is tagged with
  " a buffer variable rather than a filetype.
  let b:air_proposal = 1

  if !air#get('modifiable', 0)
    setlocal nomodifiable
  endif

  diffthis

  let session.proposal = bufnr('%')
  let s:session = session

  " R4.9 — clean up if the user wipes or closes the proposal directly.
  augroup Air
    execute 'autocmd BufWipeout <buffer=' . session.proposal . '>'
          \ 'call air#diff#on_proposal_gone()'
  augroup END

  " REQ 3.19
  if air#get('proposal_maps', 1)
    nnoremap <buffer> <silent> q :AirClose<CR>
  endif

  " Land on the first change. ]c jumps past a change that starts on line 1.
  keepjumps normal! gg
  if !diff_hlID(1, 1) && !diff_filler(1)
    silent! normal! ]c
  endif

  call air#info(printf('proposal ready (%s) — ]c [c do dp, :AirClose',
        \ a:req.scope))
endfunction

" REQ 3.10, REQ 3.12, REQ 3.15
function! air#diff#on_proposal_gone() abort
  if empty(s:session)
    return
  endif
  let session = s:session
  let s:session = {}
  let &diffopt = session.diffopt

  let current = win_getid()
  if win_gotoid(session.srcwin)
    if bufnr('%') == session.srcbuf
      call s:restore_winopts(session.srcwin_opts)
    endif
    call win_gotoid(current)
  endif

  " BufWipeout can fire before the proposal window disappears.
  if has('timers')
    call timer_start(0, function('s:restore_layout', [session]))
  endif
endfunction

" REQ 3.9
function! air#diff#close() abort
  if empty(s:session)
    return
  endif
  let session = s:session
  let current = win_getid()
  if bufexists(session.proposal)
    execute 'silent! bwipeout!' session.proposal
  else
    call air#diff#on_proposal_gone()
  endif
  call s:restore_layout(session)
  if !win_gotoid(current)
    call win_gotoid(session.srcwin)
  endif
endfunction

" Inspection helper for tests and diagnostics.
function! air#diff#sessions() abort
  let sessions = {}
  if !empty(s:session)
    let sessions[s:session.srcbuf] = copy(s:session)
  endif
  return sessions
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
