" vim-air — target text extraction (§5)

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:names = ['buffer', 'range', 'paragraph', 'section', 'motion']

function! air#scope#names() abort
  return copy(s:names)
endfunction

" Returns {'name': ..., 'start': lnum, 'end': lnum} (1-based, inclusive).
function! air#scope#resolve(name, line1, line2) abort
  let last = line('$')

  if a:name ==# 'buffer'
    return {'name': 'buffer', 'start': 1, 'end': last}
  endif

  if a:name ==# 'range' || a:name ==# 'motion'
    let s = a:line1 > 0 ? a:line1 : line('.')
    let e = a:line2 > 0 ? a:line2 : s
    if s > e
      let [s, e] = [e, s]
    endif
    return {'name': a:name, 'start': max([1, s]), 'end': min([last, e])}
  endif

  if a:name ==# 'paragraph'
    return extend(s:paragraph(), {'name': 'paragraph'})
  endif

  if a:name ==# 'section'
    return extend(s:section(), {'name': 'section'})
  endif

  throw 'air: unknown scope ' . a:name . ' (try ' . join(s:names, ', ') . ')'
endfunction

" R5.3 — contiguous non-blank block around the cursor.
function! s:paragraph() abort
  let cur = line('.')
  let last = line('$')

  if getline(cur) =~# '^\s*$'
    " Sitting on a blank line: reach forward to the next paragraph.
    let cur = cur
    while cur <= last && getline(cur) =~# '^\s*$'
      let cur += 1
    endwhile
    if cur > last
      throw 'air: no paragraph at cursor'
    endif
  endif

  let s = cur
  while s > 1 && getline(s - 1) !~# '^\s*$'
    let s -= 1
  endwhile

  let e = cur
  while e < last && getline(e + 1) !~# '^\s*$'
    let e += 1
  endwhile

  return {'start': s, 'end': e}
endfunction

" R5.4 — Markdown heading through the next heading of same or higher level.
function! s:section() abort
  let cur = line('.')
  let last = line('$')
  let pat = '^#\{1,6}\s'

  let s = 0
  let l = cur
  while l >= 1
    if getline(l) =~# pat
      let s = l
      break
    endif
    let l -= 1
  endwhile

  if s == 0
    " No heading above the cursor: fall back to the whole buffer.
    return {'start': 1, 'end': last}
  endif

  let level = strlen(matchstr(getline(s), '^#\+'))
  let e = last
  let l = s + 1
  while l <= last
    let line = getline(l)
    if line =~# pat
      let lvl = strlen(matchstr(line, '^#\+'))
      if lvl <= level
        let e = l - 1
        break
      endif
    endif
    let l += 1
  endwhile

  return {'start': s, 'end': e}
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
