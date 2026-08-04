" vim-air — Vim AI Review
" Propose LLM revisions to a buffer and review them in Vim's native diff mode.
" Maintainer: you
" License: MIT

scriptencoding utf-8

if exists('g:loaded_air')
  finish
endif
let g:loaded_air = 1

if !has('nvim') && v:version < 800
  echohl ErrorMsg
  echomsg 'vim-air requires Vim 8.0+ or Neovim'
  echohl None
  finish
endif

let s:save_cpo = &cpoptions
set cpoptions&vim

" R0.2 / R4.1 — primary command plus Air-prefixed satellites.
command! -range -nargs=* -complete=customlist,air#complete Air
      \ call air#revise(<range> ? 'range' : '', <line1>, <line2>, <q-args>)

command! -nargs=* -complete=customlist,air#complete AirBuffer
      \ call air#revise('buffer', 0, 0, <q-args>)
command! -nargs=* -complete=customlist,air#complete AirParagraph
      \ call air#revise('paragraph', 0, 0, <q-args>)
command! -nargs=* -complete=customlist,air#complete AirSection
      \ call air#revise('section', 0, 0, <q-args>)

command! -nargs=0 AirAbort call air#abort()
command! -nargs=0 AirClose call air#diff#close()
command! -nargs=0 AirLog   call air#log#show()

" R0.7 — <Plug> mappings only; no default keys (R9.2).
nnoremap <silent> <Plug>AirRevise    :Air<CR>
nnoremap <silent> <Plug>AirParagraph :AirParagraph<CR>
nnoremap <silent> <Plug>AirSection   :AirSection<CR>
xnoremap <silent> <Plug>AirRevise    :Air<CR>
nnoremap <silent> <Plug>AirMotion    :<C-u>set operatorfunc=air#motion<CR>g@
nnoremap <silent> <Plug>AirClose     :AirClose<CR>
nnoremap <silent> <Plug>AirAbort     :AirAbort<CR>

augroup Air
  autocmd!
augroup END

let &cpoptions = s:save_cpo
unlet s:save_cpo
