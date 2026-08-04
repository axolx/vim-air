" vim-air — small helpers

let s:save_cpo = &cpoptions
set cpoptions&vim

" uniq() needs Vim 8.0.1440+; keep working on older builds.
function! air#util#uniq(list) abort
  if exists('*uniq')
    return uniq(copy(a:list))
  endif
  let out = []
  for item in a:list
    if empty(out) || out[-1] !=# item
      call add(out, item)
    endif
  endfor
  return out
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
