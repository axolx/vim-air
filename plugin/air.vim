" vim-air — Vim AI Review
" Propose LLM revisions to a buffer and review them in Vim's native diff mode.
" Maintainer: you
" License: MIT

scriptencoding utf-8

if exists('g:loaded_air')
  finish
endif
let g:loaded_air = 1

" REQ 13.1, REQ 13.4
if !has('nvim') && v:version < 800
  echohl ErrorMsg
  echomsg 'vim-air requires Vim 8.0+ or Neovim'
  echohl None
  finish
endif

let s:save_cpo = &cpoptions
set cpoptions&vim

" R0.2 / R4.1 — primary command plus Air-prefixed satellites.
" REQ 1.1, REQ 1.2, REQ 1.9, REQ 2.2
command! -range -nargs=* -complete=customlist,air#complete Air
      \ call air#revise(<range> ? 'range' : '', <line1>, <line2>, <q-args>)

" REQ 2.9
command! -nargs=* -complete=customlist,air#complete AirBuffer
      \ call air#revise('buffer', 0, 0, <q-args>)
command! -nargs=* -complete=customlist,air#complete AirParagraph
      \ call air#revise('paragraph', 0, 0, <q-args>)
command! -nargs=* -complete=customlist,air#complete AirSection
      \ call air#revise('section', 0, 0, <q-args>)

" REQ 3.9, REQ 10.4, REQ 15.2, REQ 14.6
command! -nargs=0 AirAbort call air#abort()
command! -nargs=0 AirClose call air#diff#close()
command! -nargs=0 AirLog   call air#log#show()

" R0.7 — <Plug> mappings only; no default keys (R9.2).
" REQ 14.1, REQ 14.2
nnoremap <silent> <Plug>AirRevise    :Air<CR>
nnoremap <silent> <Plug>AirParagraph :AirParagraph<CR>
nnoremap <silent> <Plug>AirSection   :AirSection<CR>
xnoremap <silent> <Plug>AirRevise    :Air<CR>
" REQ 2.8
nnoremap <silent> <Plug>AirMotion    :<C-u>set operatorfunc=air#motion<CR>g@
nnoremap <silent> <Plug>AirClose     :AirClose<CR>
nnoremap <silent> <Plug>AirAbort     :AirAbort<CR>

augroup Air
  autocmd!
augroup END

let &cpoptions = s:save_cpo
unlet s:save_cpo
