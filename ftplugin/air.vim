" ftplugin for the air prompt buffer (R8a.4, R8a.5)

scriptencoding utf-8

if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

" R8a.5 — submission is explicit so <CR> stays a literal newline in insert mode.
" REQ 7.3, REQ 7.4, REQ 7.5, REQ 7.6
nnoremap <buffer> <silent> <CR>  :call air#prompt#submit()<CR>
nnoremap <buffer> <silent> q     :call air#prompt#cancel()<CR>
nnoremap <buffer> <silent> <C-c> :call air#prompt#cancel()<CR>
inoremap <buffer> <silent> <C-s> <Esc>:call air#prompt#submit()<CR>
nnoremap <buffer> <silent> <C-s> :call air#prompt#submit()<CR>

" R8a.7 — prompt history recall.
" REQ 8.4
nnoremap <buffer> <silent> <C-p> :call air#prompt#recall(-1)<CR>
nnoremap <buffer> <silent> <C-n> :call air#prompt#recall(1)<CR>

let b:undo_ftplugin = 'silent! nunmap <buffer> <CR>'
      \ . ' | silent! nunmap <buffer> q'
      \ . ' | silent! nunmap <buffer> <C-c>'
      \ . ' | silent! iunmap <buffer> <C-s>'
      \ . ' | silent! nunmap <buffer> <C-s>'
      \ . ' | silent! nunmap <buffer> <C-p>'
      \ . ' | silent! nunmap <buffer> <C-n>'
