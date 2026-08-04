" vim-air — diff session management (§4, R8.3, R8.4)

let s:save_cpo = &cpoptions
set cpoptions&vim

" srcbuf -> session state
let s:sessions = {}

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

" R4.3/R4.4 — the response lands in a scratch buffer beside the original.
function! air#diff#open(req, lines) abort
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

  " Only one live session per source buffer.
  if has_key(s:sessions, a:req.srcbuf)
    call air#diff#close_session(a:req.srcbuf)
  endif

  execute srcwin . 'wincmd w'
  let session = {
        \ 'srcbuf': a:req.srcbuf,
        \ 'srcwin_opts': s:save_winopts(),
        \ 'diffopt': &diffopt,
        \ 'scope': a:req.scope,
        \ }

  " R8.4 — better hunk granularity for prose, restored on close.
  let want = air#get('diffopt', 'internal,filler,algorithm:patience')
  if !empty(want)
    let &diffopt = want
  endif

  diffthis

  let ft = getbufvar(a:req.srcbuf, '&filetype')
  let ff = getbufvar(a:req.srcbuf, '&fileformat')
  let fe = getbufvar(a:req.srcbuf, '&fileencoding')

  let split = air#get('split', 'vertical') ==# 'horizontal' ? '' : 'vertical'
  execute split . ' new'

  let name = 'air://proposal/' . fnamemodify(bufname(a:req.srcbuf), ':t')
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
  let b:air_srcbuf = a:req.srcbuf

  if !air#get('modifiable', 0)
    setlocal nomodifiable
  endif

  diffthis

  let session.proposal = bufnr('%')
  let s:sessions[a:req.srcbuf] = session

  " R4.9 — clean up if the user wipes or closes the proposal directly.
  augroup Air
    execute 'autocmd BufWipeout <buffer=' . session.proposal . '>'
          \ 'call air#diff#on_proposal_gone(' . a:req.srcbuf . ')'
  augroup END

  call s:map_proposal()

  " Land on the first change.
  keepjumps normal! gg
  silent! normal! ]c

  call air#info(printf('proposal ready (%s) — ]c [c do dp, :AirClose',
        \ a:req.scope))
endfunction

function! s:map_proposal() abort
  if !air#get('proposal_maps', 1)
    return
  endif
  nnoremap <buffer> <silent> q :AirClose<CR>
endfunction

function! air#diff#on_proposal_gone(srcbuf) abort
  if !has_key(s:sessions, a:srcbuf)
    return
  endif
  let session = s:sessions[a:srcbuf]
  unlet s:sessions[a:srcbuf]
  let &diffopt = session.diffopt

  let win = bufwinnr(a:srcbuf)
  if win != -1
    let cur = winnr()
    execute win . 'wincmd w'
    call s:restore_winopts(session.srcwin_opts)
    if winnr() != cur && cur <= winnr('$')
      execute cur . 'wincmd w'
    endif
  endif
endfunction

" R4.9 — :AirClose from either side of the diff.
function! air#diff#close() abort
  let srcbuf = 0

  if exists('b:air_proposal')
    let srcbuf = b:air_srcbuf
  elseif has_key(s:sessions, bufnr('%'))
    let srcbuf = bufnr('%')
  else
    for [key, session] in items(s:sessions)
      if session.proposal == bufnr('%')
        let srcbuf = str2nr(key)
        break
      endif
    endfor
  endif

  if !srcbuf
    call air#info('no air diff session here')
    return
  endif

  call air#diff#close_session(srcbuf)
endfunction

function! air#diff#close_session(srcbuf) abort
  if !has_key(s:sessions, a:srcbuf)
    return
  endif
  let proposal = s:sessions[a:srcbuf].proposal

  let win = bufwinnr(proposal)
  if win != -1
    execute win . 'wincmd c'
  endif
  if bufexists(proposal)
    " Triggers BufWipeout -> on_proposal_gone.
    execute 'silent! bwipeout!' proposal
  else
    call air#diff#on_proposal_gone(a:srcbuf)
  endif

  let win = bufwinnr(a:srcbuf)
  if win != -1
    execute win . 'wincmd w'
  endif
endfunction

function! air#diff#sessions() abort
  return copy(s:sessions)
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
