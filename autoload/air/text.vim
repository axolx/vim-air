" vim-air — response text normalization (§8)

let s:save_cpo = &cpoptions
set cpoptions&vim

" A line is "blank" for trimming purposes if it holds nothing but whitespace,
" including the invisible blanks models like to emit.
let s:blank = '^\%(\s\|\%u00a0\|\%u200b\|\%u2060\|\%ufeff\)*$'

function! air#text#blank_pattern() abort
  return s:blank
endfunction

" Models prefix responses with byte-order marks and zero-width characters often
" enough that they have to be scrubbed: they render as a stray glyph, they can
" leave a first line that looks blank but is not, and a BOM in front of a code
" fence defeats fence detection.
function! air#text#strip_invisible(text) abort
  " U+FEFF is never meaningful inside a revision, so remove it everywhere.
  let t = substitute(a:text, '\%ufeff', '', 'g')
  " Zero-width and non-breaking blanks are only stripped at the very start:
  " U+200D is load-bearing inside emoji sequences.
  return substitute(t,
        \ '^\%(\%u200b\|\%u200c\|\%u200d\|\%u2060\|\%u00a0\)\+', '', '')
endfunction

" CLI tools colour their output when they think a terminal is attached; scrub
" escape sequences before the text is treated as a revision.
function! air#text#strip_ansi(text) abort
  let t = substitute(a:text, "\e\\[[0-9;?]*[ -/]*[@-~]", '', 'g')
  let t = substitute(t, "\e\\][^\x07\e]*\\(\x07\\|\e\\\\\\)", '', 'g')
  let t = substitute(t, "\e[@-Z\\\\-_]", '', 'g')
  return substitute(t, "\r\\ze\n", '', 'g')
endfunction

" R8.1 — drop a single wrapping code fence if the model added one.
function! air#text#strip_fences(lines) abort
  let lines = air#text#trim_blank_edges(a:lines)

  " Note: '~' is magic in a regex (last substitute string), so it must be
  " escaped or Vim raises E33 when no substitute has run yet.
  if len(lines) >= 2 && lines[0] =~# '^\s*\(```\|\~\~\~\)'
    let fence = matchstr(lines[0], '```\|\~\~\~')
    if lines[-1] =~# '^\s*' . escape(fence, '~') . '\s*$'
      call remove(lines, 0)
      call remove(lines, -1)
    endif
  endif

  return lines
endfunction

function! air#text#trim_blank_edges(lines) abort
  let lines = copy(a:lines)
  while len(lines) && lines[0] =~# s:blank
    call remove(lines, 0)
  endwhile
  while len(lines) && lines[-1] =~# s:blank
    call remove(lines, -1)
  endwhile
  return lines
endfunction

" R8.2 — normalize edges to match the original region so the diff shows only
" real changes.
function! air#text#clean(text, target_lines, fileformat) abort
  let text = air#text#strip_invisible(air#text#strip_ansi(a:text))
  let lines = split(text, "\n", 1)
  let lines = map(lines, 'substitute(v:val, "\r$", "", "")')
  let lines = air#text#strip_fences(lines)
  let lines = air#text#trim_blank_edges(lines)

  if empty(lines)
    return []
  endif

  " Re-attach the leading/trailing blank lines the original region had.
  let lead = 0
  for l in a:target_lines
    if l =~# s:blank
      let lead += 1
    else
      break
    endif
  endfor
  let trail = 0
  for i in range(len(a:target_lines) - 1, 0, -1)
    if a:target_lines[i] =~# s:blank
      let trail += 1
    else
      break
    endif
  endfor
  " A region that is entirely blank has no meaningful lead/trail split.
  if lead == len(a:target_lines)
    let lead = 0
    let trail = 0
  endif

  " Don't let the model invent indentation on the first line. Only applied when
  " the original did not start indented, so real indentation is preserved when
  " revising an indented region.
  if lead < len(a:target_lines) && a:target_lines[lead] !~# '^\s'
        \ && lines[0] =~# '^\s'
    let lines[0] = substitute(lines[0], '^\s\+', '', '')
  endif

  let out = repeat([''], lead) + lines + repeat([''], trail)
  return out
endfunction

" Splice revised region lines back into the full buffer (R5.2).
function! air#text#splice(all_lines, start, end, lines) abort
  let before = a:start > 1 ? a:all_lines[0 : a:start - 2] : []
  let after  = a:end < len(a:all_lines) ? a:all_lines[a:end :] : []
  return before + a:lines + after
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
