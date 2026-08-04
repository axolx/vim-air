" vim-air — request/response log (R7.9, :AirLog)

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:log = []

function! air#log#add(msg) abort
  call add(s:log, strftime('%H:%M:%S') . ' ' . a:msg)
  let max = air#get('log_size', 50)
  if len(s:log) > max
    let s:log = s:log[-max :]
  endif
endfunction

function! air#log#entries() abort
  return copy(s:log)
endfunction

function! air#log#clear() abort
  let s:log = []
endfunction

function! air#log#show() abort
  if empty(s:log)
    call air#info('log is empty')
    return
  endif

  let name = 'air://log'
  if bufexists(name)
    execute 'silent! bwipeout!' bufnr(name)
  endif

  botright new
  execute 'silent file' fnameescape(name)
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal filetype=airlog

  let lines = []
  for entry in s:log
    call extend(lines, split(entry, "\n", 1))
  endfor
  call setline(1, lines)
  setlocal nomodifiable
  nnoremap <buffer> <silent> q :close<CR>
  keepjumps normal! G
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
