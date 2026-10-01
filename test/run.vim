" vim-air test suite (R10.2). Run: make test  /  test/run.sh
" No network, no AWS and no OpenAI calls: a fake backend, stub `aws` and
" `curl` executables, and g:Air_backend.
" REQ 16.2, REQ 16.3, REQ 16.4

scriptencoding utf-8

let v:errors = []
let s:fails = 0

" Vim's silent-ex mode (-es) suppresses :echo, and writefile() refuses
" /dev/stderr there, so results are appended to $AIR_TEST_LOG and printed by
" test/run.sh.
let s:log = empty($AIR_TEST_LOG) ? tempname() : $AIR_TEST_LOG

function! s:say(msg) abort
  call writefile([a:msg], s:log, 'a')
endfunction

function! s:ok(cond, name) abort
  if a:cond
    call s:say('ok   ' . a:name)
  else
    let s:fails += 1
    call s:say('FAIL ' . a:name)
  endif
endfunction

function! s:eq(got, want, name) abort
  if a:got ==# a:want
    call s:say('ok   ' . a:name)
  else
    let s:fails += 1
    call s:say('FAIL ' . a:name)
    call s:say('     got:  ' . string(a:got))
    call s:say('     want: ' . string(a:want))
  endif
endfunction

" ------------------------------------------------------------- fake backend --

let g:air_fake_reply = ''
let g:air_fake_prompts = []
let g:air_fake_ok = 1

function! FakeBackend(payload, opts, Cb) abort
  call add(g:air_fake_prompts, a:payload.system . "\n" . a:payload.user)
  if !g:air_fake_ok
    call call(a:Cb, [{'ok': 0, 'text': '', 'raw': 'boom', 'error': 'fake failure'}])
    return
  endif
  call call(a:Cb, [{'ok': 1, 'text': g:air_fake_reply, 'raw': g:air_fake_reply,
        \ 'error': ''}])
endfunction

" Funcref hooks must be capitalized in legacy Vim (E704); see air#hook().
let g:Air_backend = function('FakeBackend')

function! s:scratch(lines) abort
  silent! only!
  enew!
  silent %delete _
  call setline(1, a:lines)
  return bufnr('%')
endfunction

function! s:goto_proposal() abort
  let session = values(air#diff#sessions())[0]
  execute bufwinnr(session.proposal) . 'wincmd w'
endfunction

function! s:reset() abort
  call air#diff#close()
  silent! only!
  let g:air_fake_prompts = []
  let g:air_fake_ok = 1
endfunction

" =============================================================== text ========

call s:say('--- text ---')

call s:eq(air#text#strip_ansi("\e[1mbold\e[0m plain"), 'bold plain',
      \ 'strip_ansi removes SGR sequences')
call s:eq(air#text#strip_ansi("a\r\nb"), "a\nb", 'strip_ansi drops CR before LF')

call s:eq(air#text#strip_fences(['```python', 'x = 1', '```']), ['x = 1'],
      \ 'strip_fences removes language-tagged fence')
call s:eq(air#text#strip_fences(['~~~', 'a', '~~~']), ['a'],
      \ 'strip_fences handles tilde fences')
call s:eq(air#text#strip_fences(['a', '```', 'b', '```']),
      \ ['a', '```', 'b', '```'],
      \ 'strip_fences leaves inner fences alone')
call s:eq(air#text#strip_fences(['', 'a', '']), ['a'],
      \ 'strip_fences trims blank edges')

call s:eq(air#text#clean("revised\n", ['orig'], 'unix'), ['revised'],
      \ 'clean strips trailing newline')
call s:eq(air#text#clean("```\nrevised\n```", ['orig'], 'unix'), ['revised'],
      \ 'clean strips fences')
call s:eq(air#text#clean("a\r\nb", ['x'], 'unix'), ['a', 'b'],
      \ 'clean normalizes CRLF')
call s:eq(air#text#clean('new', ['', 'orig', ''], 'unix'), ['', 'new', ''],
      \ 'clean restores blank edges of the original region (R8.2)')
call s:eq(air#text#clean("   \n  ", ['x'], 'unix'), [],
      \ 'clean returns empty for whitespace-only response')

" Invisible junk at the head of a response: it renders as a stray glyph, or
" leaves a first line that looks blank but is not.
call s:eq(air#text#clean("\xef\xbb\xbfALPHA", ['a'], 'unix'), ['ALPHA'],
      \ 'clean strips a leading BOM')
call s:eq(air#text#clean("\xef\xbb\xbf\nALPHA", ['a'], 'unix'), ['ALPHA'],
      \ 'clean drops a first line containing only a BOM')
call s:eq(air#text#clean("\u200bALPHA", ['a'], 'unix'), ['ALPHA'],
      \ 'clean strips a leading zero-width space')
call s:eq(air#text#clean("\u2060ALPHA", ['a'], 'unix'), ['ALPHA'],
      \ 'clean strips a leading word joiner')
call s:eq(air#text#clean("\u00a0ALPHA", ['a'], 'unix'), ['ALPHA'],
      \ 'clean strips a leading non-breaking space')
call s:eq(air#text#clean("\xef\xbb\xbf```\nALPHA\n```", ['a'], 'unix'),
      \ ['ALPHA'], 'a BOM does not defeat fence stripping')
call s:eq(air#text#clean("mid\xef\xbb\xbfword", ['a'], 'unix'), ['midword'],
      \ 'a BOM is removed anywhere, not just at the start')
call s:eq(air#text#clean(' ALPHA', ['alpha'], 'unix'), ['ALPHA'],
      \ 'clean strips invented indentation on the first line')
call s:eq(air#text#clean('    return x', ['    return y'], 'unix'),
      \ ['    return x'],
      \ 'real indentation is preserved when the original was indented')
call s:eq(air#text#clean("\u200bALPHA", ['', 'alpha'], 'unix'), ['', 'ALPHA'],
      \ 'blank-edge restoration still works after scrubbing')

" U+200D is load-bearing inside emoji, so it is only stripped at the head.
call s:eq(air#text#clean("a\u200db", ['x'], 'unix'), ["a\u200db"],
      \ 'a zero-width joiner inside the text is left alone')
call s:eq(air#text#clean("\u200dALPHA", ['a'], 'unix'), ['ALPHA'],
      \ 'a leading zero-width joiner is stripped')

call s:eq(air#text#trim_blank_edges(["\u00a0", 'a', "\u200b"]), ['a'],
      \ 'lines of invisible blanks count as blank edges')

call s:eq(air#text#splice(['a', 'b', 'c'], 2, 2, ['B']), ['a', 'B', 'c'],
      \ 'splice replaces a middle line')
call s:eq(air#text#splice(['a', 'b', 'c'], 1, 3, ['x']), ['x'],
      \ 'splice replaces whole buffer')
call s:eq(air#text#splice(['a', 'b', 'c'], 3, 3, ['C', 'D']),
      \ ['a', 'b', 'C', 'D'], 'splice can grow the tail')

" ============================================================== scope ========

call s:say('--- scope ---')

call s:scratch(['one', 'two', '', 'three', 'four', 'five'])

call cursor(1, 1)
call s:eq(air#scope#resolve('buffer', 0, 0),
      \ {'name': 'buffer', 'start': 1, 'end': 6}, 'scope buffer spans all lines')

call cursor(1, 1)
call s:eq(air#scope#resolve('paragraph', 0, 0),
      \ {'name': 'paragraph', 'start': 1, 'end': 2}, 'paragraph at top')

call cursor(5, 1)
call s:eq(air#scope#resolve('paragraph', 0, 0),
      \ {'name': 'paragraph', 'start': 4, 'end': 6}, 'paragraph in middle block')

call cursor(3, 1)
call s:eq(air#scope#resolve('paragraph', 0, 0),
      \ {'name': 'paragraph', 'start': 4, 'end': 6},
      \ 'paragraph from blank line reaches forward')

call s:eq(air#scope#resolve('range', 2, 4),
      \ {'name': 'range', 'start': 2, 'end': 4}, 'range honours line1/line2')
call s:eq(air#scope#resolve('range', 4, 2),
      \ {'name': 'range', 'start': 2, 'end': 4}, 'range normalizes reversed input')
call s:eq(air#scope#resolve('range', 1, 99),
      \ {'name': 'range', 'start': 1, 'end': 6}, 'range clamps to buffer end')
call cursor(3, 1)
call s:eq(air#scope#resolve('range', 0, 0),
      \ {'name': 'range', 'start': 3, 'end': 3},
      \ 'range with no line numbers falls back to the cursor line')

let s:threw = 0
try
  call air#scope#resolve('bogus', 0, 0)
catch /^air:/
  let s:threw = 1
endtry
call s:ok(s:threw, 'unknown scope throws')

call s:scratch(['# One', 'a', '## Two', 'b', '### Three', 'c', '# Four', 'd'])

call cursor(4, 1)
call s:eq(air#scope#resolve('section', 0, 0),
      \ {'name': 'section', 'start': 3, 'end': 6},
      \ 'section stops at same-or-higher heading, keeps deeper ones')

call cursor(2, 1)
call s:eq(air#scope#resolve('section', 0, 0),
      \ {'name': 'section', 'start': 1, 'end': 6}, 'H1 section swallows subsections')

call cursor(8, 1)
call s:eq(air#scope#resolve('section', 0, 0),
      \ {'name': 'section', 'start': 7, 'end': 8}, 'last section runs to EOF')

call s:scratch(['no headings here', 'at all'])
call cursor(1, 1)
call s:eq(air#scope#resolve('section', 0, 0),
      \ {'name': 'section', 'start': 1, 'end': 2},
      \ 'section falls back to whole buffer')

" =============================================================== args ========

call s:say('--- args ---')

call s:eq(air#parse_args('tighten').source, 'named', 'named prompt resolves')
call s:eq(air#parse_args('tighten').prompt, air#prompt#named()['tighten'],
      \ 'named prompt expands to its text')
call s:eq(air#parse_args('make it shorter').prompt, 'make it shorter',
      \ 'literal prompt passes through')
call s:eq(air#parse_args('-scope=paragraph tighten').scope, 'paragraph',
      \ '-scope= is parsed')
call s:eq(air#parse_args('-scope=paragraph tighten').source, 'named',
      \ 'flags and named prompt combine')

call setreg('p', "from register\n")
call s:eq(air#parse_args('@p').prompt, 'from register', 'register prompt (R8a.9)')
call s:eq(air#parse_args('@p').source, 'register', 'register source tagged')

let s:threw = 0
try
  call air#parse_args('-nope x')
catch /^air:/
  let s:threw = 1
endtry
call s:ok(s:threw, 'unknown flag throws')
for s:alias in ['-model=x', '-f prompt.txt', '-m=x', '-file prompt.txt', '-f=prompt.txt']
  let s:threw = 0
  try
    call air#parse_args(s:alias . ' go')
  catch /^air: unknown option/
    let s:threw = 1
  endtry
  call s:ok(s:threw, 'removed alias ' . split(s:alias)[0][0 : 5] . ' is an unknown option')
endfor
call setreg('z', '')
call s:eq(air#parse_args('@z').prompt, '',
      \ 'an empty register gives an empty prompt, so the prompt buffer opens')

call s:ok(index(air#complete('tig', '', 0), 'tighten') >= 0,
      \ 'completion offers named prompts')

call s:eq(air#complete('-model', '', 0), [], 'removed model option is not completed')
call s:eq(air#complete('-f', '', 0), [], 'removed file option is not completed')

" ============================================================= compose =======

call s:say('--- compose ---')

call s:scratch(['alpha', 'beta', 'gamma'])
let s:req = air#request(air#scope#resolve('buffer', 0, 0),
      \ {'prompt': 'tighten it', 'scope': ''})
let s:composed = air#prompt#compose(s:req)

call s:eq(sort(keys(s:composed)), ['system', 'user'],
      \ 'compose returns a {system, user} payload')
call s:ok(s:composed.system =~# 'Return ONLY the revised text',
      \ 'system prompt carries the only-text instruction (R6.4)')
call s:ok(s:composed.user !~# 'Return ONLY the revised text',
      \ 'system prompt is not duplicated into the user message')
call s:ok(s:composed.user =~# 'tighten it', 'compose includes the instruction')
call s:ok(s:composed.user =~# "alpha\nbeta\ngamma",
      \ 'compose includes the document')
call s:ok(s:composed.user !~# 'BEGIN REGION',
      \ 'whole-buffer scope needs no region markers')

let s:req2 = air#request(air#scope#resolve('range', 2, 2),
      \ {'prompt': 'fix', 'scope': ''})
let s:composed2 = air#prompt#compose(s:req2).user
call s:ok(s:composed2 =~# '<<< BEGIN REGION >>>\nbeta\n<<< END REGION >>>',
      \ 'partial scope marks the region inside full context (R5.2)')
call s:ok(s:composed2 =~# 'alpha', 'partial scope still sends surrounding context')

let s:req3 = air#request(air#scope#resolve('buffer', 0, 0),
      \ {'prompt': 'lint this {filetype}', 'scope': ''})
let b:dummy = 1
setlocal filetype=markdown
let s:req3.filetype = 'markdown'
call s:ok(air#prompt#compose(s:req3).user =~# 'lint this markdown',
      \ 'compose expands {filetype} placeholder (R6.5)')
let s:req3.filename = 'R&D~\1.md'
call s:ok(stridx(air#prompt#compose(s:req3).user, 'lint this markdown') >= 0
      \ && stridx(air#prompt#compose(extend(copy(s:req3),
      \ {'prompt': 'edit {filename}'})).user, 'edit R&D~\1.md') >= 0,
      \ 'placeholders insert &, ~ and \ literally (R6.5)')

" ========================================================== diff session ====

call s:say('--- diff session ---')

call s:reset()
let s:src = s:scratch(['alpha', 'beta', 'gamma'])
let s:orig_diffopt = &diffopt
let g:air_fake_reply = "ALPHA\nbeta\ngamma"

let g:air_split = 'horizontal'
call air#revise('buffer', 1, 3, 'shout the first line')
unlet g:air_split
call s:ok(winwidth(0) < &columns, 'review stays vertical with the removed split setting')

call s:eq(len(g:air_fake_prompts), 1, 'backend called once')
call s:eq(winnr('$'), 2, 'diff split opened (R4.4)')
call s:eq(bufnr('%'), s:src, 'focus stays in the source window (REQ 3.8)')
call s:eq(line('.'), 1, 'cursor lands on the first change (REQ 3.8)')
call s:goto_proposal()
call s:ok(exists('b:air_proposal'), 'proposal buffer is tagged (R0.5)')
call s:eq(getline(1, '$'), ['ALPHA', 'beta', 'gamma'],
      \ 'proposal holds the full buffer with the revision spliced in')
call s:ok(&diff, 'proposal window is in diff mode')
call s:ok(!&modifiable, 'proposal is nomodifiable by default (R4.6)')
call s:eq(&buftype, 'nofile', 'proposal is a scratch buffer')
call s:ok(getwinvar(bufwinnr(s:src), '&diff'), 'source window is in diff mode')
call s:ok(&diffopt =~# 'algorithm:histogram',
      \ 'diffopt augmented for the session (R8.4)')
call s:ok(&diffopt =~# 'linematch:60', 'changed lines are aligned (R8.4)')
call s:ok(&diffopt =~# 'iwhite' && &diffopt =~# 'followwrap',
      \ 'whitespace changes are ignored and wrap is followed (R8.4)')
call s:ok(&diffopt =~# 'inline:word' && &diffopt !~# 'inline:char',
      \ 'word-level highlighting replaces the user inline setting (R8.4)')

" Native merge commands still drive everything (R4.7).
let s:pwin = winnr()
execute bufwinnr(s:src) . 'wincmd w'
keepjumps normal! gg
silent! normal! ]c
silent! normal! do
call s:eq(getline(1, '$'), ['ALPHA', 'beta', 'gamma'],
      \ 'native do pulls the hunk into the source buffer (R4.7)')

call air#diff#close()
call s:eq(winnr('$'), 1, 'AirClose closes the split (R4.9)')
call s:ok(!&diff, 'AirClose runs diffoff on the source window (R4.9)')
call s:eq(&diffopt, s:orig_diffopt, 'AirClose restores global diffopt (R8.4)')
call s:eq(len(air#diff#sessions()), 0, 'session state cleared')

" R8.4 — a diffopt item this Vim rejects is dropped, not fatal.
call s:reset()
call s:scratch(['one', 'two'])
set diffopt=internal,filler,iwhite
let s:user_diffopt = &diffopt
let g:air_diffopt = 'no-such-item:1,filler,algorithm:patience'
let g:air_fake_reply = "ONE\ntwo"
call air#revise('buffer', 1, 2, 'shout')
call s:eq(winnr('$'), 2, 'an unsupported diffopt item does not stop the session')
call s:eq(&diffopt, 'internal,iwhite,filler,algorithm:patience',
      \ 'session items are added to the user diffopt, the unsupported one dropped')
unlet g:air_diffopt
call air#diff#close()
call s:eq(&diffopt, s:user_diffopt, 'diffopt is still restored afterwards')
let &diffopt = s:orig_diffopt

" REQ 3.7 — dp from a nomodifiable proposal still sends a hunk to the source.
call s:reset()
let s:src = s:scratch(['alpha', 'beta'])
let g:air_fake_reply = "ALPHA\nbeta"
call air#revise('buffer', 1, 2, 'shout')
call s:goto_proposal()
call s:ok(!&modifiable, 'proposal is nomodifiable for the dp check')
silent! normal! dp
call s:eq(getbufline(s:src, 1, '$'), ['ALPHA', 'beta'],
      \ 'dp in the proposal sends the hunk to the source buffer')
call air#diff#close()

" REQ 3.6, REQ 3.19 — g:air_modifiable and g:air_proposal_maps.
call s:reset()
call s:scratch(['alpha', 'beta'])
let g:air_modifiable = 1
let g:air_proposal_maps = 0
let g:air_fake_reply = "ALPHA\nbeta"
call air#revise('buffer', 1, 2, 'shout')
call s:goto_proposal()
call s:ok(&modifiable, 'g:air_modifiable leaves the proposal modifiable')
call s:ok(empty(maparg('q', 'n')), 'g:air_proposal_maps = 0 skips the q map')
call air#diff#close()
unlet g:air_modifiable g:air_proposal_maps

" R4.9 — window sizes the user set survive the session.
call s:reset()
let s:src = s:scratch(['alpha', 'beta'])
vnew
wincmd p
vertical resize 60
let s:layout = winrestcmd()
let g:air_fake_reply = "ALPHA\nbeta"
call air#revise('buffer', 1, 2, 'shout')
call s:eq(winnr('$'), 3, 'proposal opened beside two windows')
call air#diff#close()
call s:eq(winrestcmd(), s:layout, 'AirClose restores window sizes (R4.9)')

" The cursor lands on the first change, even when it starts on line 1.
call s:reset()
call s:scratch(['a', 'b', 'c', 'd', 'e'])
let g:air_fake_reply = "A\nb\nc\nD\ne"
call air#revise('buffer', 1, 5, 'shout a and d')
call s:eq(line('.'), 1, 'cursor stays on a change that starts on line 1')
call air#diff#close()

call s:reset()
call s:scratch(['a', 'b', 'c', 'd', 'e'])
let g:air_fake_reply = "a\nb\nc\nD\ne"
call air#revise('buffer', 1, 5, 'shout d')
call s:eq(line('.'), 4, 'cursor lands on the first change')
call air#diff#close()

" A direct :quit of the proposal restores them on the next tick.
call s:reset()
let s:src = s:scratch(['alpha', 'beta'])
vnew
wincmd p
vertical resize 60
let s:layout = winrestcmd()
call air#revise('buffer', 1, 2, 'shout')
execute bufwinnr(air#diff#sessions()[s:src].proposal) . 'wincmd w'
quit
sleep 20m
call s:eq(winrestcmd(), s:layout, ':quit on the proposal restores window sizes')

" R8.3 — identical response opens nothing.
call s:reset()
call s:scratch(['same', 'lines'])
let g:air_fake_reply = "same\nlines"
call air#revise('buffer', 1, 2, 'do nothing')
call s:eq(winnr('$'), 1, 'identical response opens no split (R8.3)')

" Partial scope splices into full-buffer context.
call s:reset()
call s:scratch(['keep1', 'change', 'keep2'])
let g:air_fake_reply = 'CHANGED'
call air#revise('range', 2, 2, 'shout it')
call s:eq(line('.'), 2, 'cursor lands on a first change below line 1 (REQ 3.8)')
call s:goto_proposal()
call s:eq(getline(1, '$'), ['keep1', 'CHANGED', 'keep2'],
      \ 'partial revision spliced into full buffer (R5.2)')
call air#diff#close()

" Keep tabline height fixed while comparing window sizes across tabs.
let s:saved_showtabline = &showtabline
set showtabline=2

" One review across tabs, with source options and layout restored on replacement.
call s:reset()
let s:first_src = s:scratch(['first', 'buffer'])
setlocal wrap foldmethod=manual foldcolumn=2 noscrollbind nocursorbind
let s:first_win = win_getid()
vnew
wincmd p
vertical resize 55
let s:first_layout = winrestcmd()
let g:air_fake_reply = "FIRST\nbuffer"
call air#revise('buffer', 1, 2, 'shout')
let s:first_proposal = air#diff#sessions()[s:first_src].proposal
tabnew
let s:second_src = bufnr('%')
call setline(1, ['second', 'buffer'])
let g:air_fake_reply = "SECOND\nbuffer"
call air#revise('buffer', 1, 2, 'shout')
let s:second_win = win_getid()
call s:eq(len(air#diff#sessions()), 1, 'only one review exists across tabs')
call s:ok(!bufexists(s:first_proposal), 'new review wipes the old proposal')
call s:ok(has_key(air#diff#sessions(), s:second_src), 'new source owns the review')
call win_gotoid(s:first_win)
call s:ok(!&diff && &wrap && &foldmethod ==# 'manual' && &foldcolumn == 2
      \ && !&scrollbind && !&cursorbind, 'replacement restores the old source options')
call s:eq(winrestcmd(), s:first_layout, 'replacement restores the old tab layout')
call win_gotoid(s:second_win)
call s:ok(&diffopt =~# 'algorithm:histogram,indent-heuristic,linematch:60,'
      \ . 'inline:word,iwhite,followwrap$',
      \ 'replacement retains the review diff options')
call air#diff#close()
call s:eq(&diffopt, s:orig_diffopt, 'replacement restores the original global diffopt')
tabclose!

" A proposal wiped from another tab restores the actual source window.
call s:reset()
let s:src = s:scratch(['alpha', 'beta'])
setlocal wrap foldmethod=manual foldcolumn=3 noscrollbind nocursorbind
let s:source_win = win_getid()
vnew
wincmd p
vertical resize 50
let s:layout = winrestcmd()
let g:air_fake_reply = "ALPHA\nbeta"
call air#revise('buffer', 1, 2, 'shout')
let s:proposal = air#diff#sessions()[s:src].proposal
tabnew
let s:other_win = win_getid()
execute 'bwipeout!' s:proposal
sleep 20m
call s:eq(win_getid(), s:other_win, 'cross-tab cleanup preserves focus')
call win_gotoid(s:source_win)
call s:ok(!&diff && &wrap && &foldmethod ==# 'manual' && &foldcolumn == 3
      \ && !&scrollbind && !&cursorbind, 'cross-tab wipe restores source options')
call s:eq(winrestcmd(), s:layout, 'cross-tab wipe restores source layout')
call s:eq(&diffopt, s:orig_diffopt, 'cross-tab wipe restores global diffopt')
call win_gotoid(s:other_win)
tabclose!

call air#revise('buffer', 1, 2, 'shout')
tabnew
let s:outside_win = win_getid()
AirClose
call s:eq(win_getid(), s:outside_win, 'AirClose from another tab preserves focus')
call s:eq(len(air#diff#sessions()), 0, 'AirClose works from an unrelated window')
call win_gotoid(s:source_win)
call s:ok(!&diff, 'AirClose from another tab restores the source')
call win_gotoid(s:outside_win)
tabclose!

let &showtabline = s:saved_showtabline

" An asynchronous response cannot overwrite edits made after the request.
" REQ 3.21
function! DeferredBackend(payload, opts, Cb) abort
  let g:Air_pending = a:Cb
endfunction
call s:reset()
let s:src = s:scratch(['original'])
let g:Air_backend = function('DeferredBackend')
call air#revise('buffer', 1, 1, 'revise')
call setline(1, 'user edit')
call call(g:Air_pending, [{'ok': 1, 'text': 'model edit', 'raw': '', 'error': ''}])
call s:eq(getline(1), 'user edit', 'a stale response preserves the user edit')
call s:eq(len(air#diff#sessions()), 0, 'a stale response opens no review')
call s:ok(join(air#log#entries(), "\n") =~# 'source buffer changed',
      \ 'a stale response explains how to retry')
unlet g:Air_pending
let g:Air_backend = function('FakeBackend')

" Backend failure surfaces as an error, not a split.
call s:reset()
call s:scratch(['x'])
let g:air_fake_ok = 0
let s:err = ''
try
  call air#revise('buffer', 1, 1, 'fail please')
catch
  let s:err = v:exception
endtry
call s:eq(winnr('$'), 1, 'failed request opens no split')
call s:ok(len(air#log#entries()) > 0, 'failure is logged for :AirLog (R7.9)')

call air#log#clear()
call air#error("provider failed\nmore detail")
call s:ok(execute('messages') =~# 'air: provider failed more detail',
      \ 'multiline provider errors display on one line')
call s:ok(join(air#log#entries(), "\n") =~# "provider failed\nmore detail",
      \ 'multiline provider errors retain full log detail')

" ========================================================== prompt buffer ===

call s:say('--- prompt buffer ---')

call s:reset()
let s:src = s:scratch(['alpha', 'beta'])
let g:air_fake_ok = 1
let g:air_fake_reply = "ALPHA\nbeta"

let g:air_prompt_ui = 'input'
call air#revise('buffer', 1, 2, '')
unlet g:air_prompt_ui
call s:eq(&filetype, 'air', 'bare :Air opens the prompt buffer (R8a.3)')
call s:eq(&buftype, 'nofile', 'prompt buffer is scratch (R8a.4)')
call s:ok(exists('b:air_request'), 'prompt buffer carries the request')
call s:ok(maparg('<CR>', 'n') =~# 'air#prompt#submit',
      \ '<CR> submits from normal mode (R8a.5)')
call s:ok(empty(maparg('<CR>', 'i')),
      \ '<CR> stays a literal newline in insert mode (R8a.5)')
call s:eq(getline(1, '$'), [''], 'with no history the prompt buffer starts empty')

call setline(1, ['# shout', 'the first line'])
call air#prompt#submit()

call s:eq(len(g:air_fake_prompts), 1, 'prompt buffer submission reaches backend')
call s:ok(g:air_fake_prompts[0] =~# '# shout\nthe first line',
      \ 'every line of the prompt buffer is sent, "#" lines included')
call s:ok(!empty(air#diff#sessions()), 'submission opens the diff split')
call air#diff#close()

" ==================================================== backend: dispatcher ====

call s:say('--- backend dispatcher ---')

let s:saved_backend = g:Air_backend
unlet g:Air_backend

let s:result = {}
function! Capture(r) abort
  let s:result = a:r
endfunction

let s:payload = {'system': 'SYS', 'user': 'USER'}

call s:eq(air#backend#name(), 'bedrock', 'bedrock is the default backend')
call s:ok(index(air#backend#available(), 'bedrock') >= 0,
      \ 'bedrock is discovered on the runtimepath')

let g:air_backend_name = 'nope'
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(!s:result.ok, 'unknown backend fails cleanly')
call s:ok(s:result.error =~# 'unknown backend', 'unknown backend is named')
call s:ok(s:result.error =~# 'bedrock', 'error lists available backends')

" REQ 9.3 — a name that cannot be a file still lists the backends.
let g:air_backend_name = 'open-ai'
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(s:result.error =~# 'invalid backend name', 'invalid backend name is reported')
call s:ok(s:result.error =~# 'bedrock', 'invalid name error lists available backends')

" REQ 8.1 — a refused request leaves no history; a dispatched one does.
let g:air_history = 1
let g:air_history_file = tempname()
call s:scratch(['alpha'])
call air#revise('buffer', 1, 1, 'refused prompt')
call s:eq(air#prompt#history(), [], 'a refused request is not recorded in history')
unlet g:air_backend_name
let g:Air_backend = s:saved_backend
let g:air_fake_reply = 'ALPHA'
call air#revise('buffer', 1, 1, 'sent prompt')
call s:eq(air#prompt#history(), ['sent prompt'],
      \ 'a dispatched request is recorded in history')
call air#diff#close()
unlet g:Air_backend
let g:air_history = 0

" A minimal third-party backend proves the interface is all that is required.
" It has to be a real autoload file on the runtimepath: Vim raises E746 if an
" autoload-named function is defined in a script with a different name.
let s:fakedir = tempname()
call mkdir(s:fakedir . '/autoload/air/backend', 'p')

function! s:write_fake(request_body) abort
  call writefile([
        \ 'function! air#backend#fake#check() abort',
        \ '  return get(g:, "fake_check_error", "")',
        \ 'endfunction',
        \ 'function! air#backend#fake#request(payload, opts) abort',
        \ '  let g:fake_seen = a:payload',
        \ '  return ' . a:request_body,
        \ 'endfunction',
        \ 'function! air#backend#fake#parse(result) abort',
        \ '  let g:fake_parse_result = a:result',
        \ '  return {"ok": a:result.status == 0, "text": a:result.stdout,',
        \ '        \ "error": "fake error", "warning": get(g:, "fake_warning", "")}',
        \ 'endfunction',
        \ ], s:fakedir . '/autoload/air/backend/fake.vim')
endfunction

execute 'set runtimepath^=' . s:fakedir
call s:write_fake('{"argv": ["printf", "%s", "REVISED-BY-FAKE"]}')

call s:ok(index(air#backend#available(), 'fake') >= 0,
      \ 'a backend dropped on the runtimepath is discovered')

let g:air_backend_name = 'fake'
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(s:result.ok, 'third-party backend runs through the dispatcher (R7.11)')
call s:eq(s:result.text, 'REVISED-BY-FAKE', 'backend stdout becomes the text')
call s:eq(g:fake_seen, s:payload, 'backend receives the {system, user} payload')
call s:eq(g:fake_parse_result.status, 0, 'parse() receives the exit status')

let g:fake_check_error = 'you must configure something'
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(!s:result.ok, 'check() failure short-circuits the request (R7.3)')
call s:eq(s:result.error, 'you must configure something',
      \ 'check() message is surfaced verbatim')
unlet g:fake_check_error

" Cleanup of backend-declared temp files is handled by the dispatcher.
let s:tmpfile = tempname()
call writefile(['x'], s:tmpfile)
let g:air_test_tmpfile = s:tmpfile
call s:write_fake('{"argv": ["printf", "%s", "ok"], "cleanup": [g:air_test_tmpfile]}')
runtime! autoload/air/backend/fake.vim
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(!filereadable(s:tmpfile), 'dispatcher deletes declared temp files')

" stdin transport, for backends that want it.
call s:write_fake('{"argv": ["cat"], "stdin": a:payload.user}')
runtime! autoload/air/backend/fake.vim
let s:result = {}
call air#backend#run({'system': 'S', 'user': 'piped through stdin'}, {},
      \ function('Capture'))
call s:ok(s:result.text =~# 'piped through stdin',
      \ 'dispatcher can feed a backend over stdin')

" Non-zero exit routes through the backend's own parse().
call s:write_fake('{"argv": ["false"]}')
runtime! autoload/air/backend/fake.vim
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(!s:result.ok, 'non-zero exit reported as failure (R7.9)')
call s:eq(s:result.error, 'fake error', 'backend owns its error message')

unlet g:air_backend_name
call delete(s:fakedir, 'rf')

" ====================================================== backend: bedrock ====

call s:say('--- backend: bedrock ---')

let g:air_aws_cmd = 'definitely-not-a-real-binary-xyz'
call s:ok(air#backend#bedrock#check() =~# 'not found in \$PATH',
      \ 'missing aws CLI is reported (R7.3)')
call s:ok(air#backend#bedrock#check() =~# 'g:air_aws_cmd',
      \ 'aws error suggests the fix')

let g:air_aws_cmd = 'aws'
call s:ok(air#backend#bedrock#check() =~# 'no model set',
      \ 'an unset model is reported before spawning aws')
call s:ok(air#backend#bedrock#check() =~# 'g:air_model',
      \ 'model error names the setting')

let g:air_model = 'us.anthropic.claude-sonnet-4-20250514-v1:0'
call s:eq(air#backend#bedrock#check(), '',
      \ 'check passes with aws present and a model set')

call s:eq(air#backend#bedrock#model(), g:air_model, 'global model is used')

let s:req = air#backend#bedrock#request(s:payload, {})
let s:argv = s:req.argv

call s:eq(s:argv[0], 'aws', 'argv starts with the aws CLI')
call s:eq(s:argv[1 : 2], ['bedrock-runtime', 'converse'],
      \ 'bedrock-runtime converse is the API used (R7.1)')
call s:eq(s:argv[index(s:argv, '--model-id') + 1], g:air_model,
      \ '--model-id carries the model')
call s:ok(index(s:argv, '--output') >= 0, 'json output is requested')
call s:ok(index(s:argv, '--no-cli-pager') >= 0, 'the pager is disabled')

" Payloads travel in files, not argv: prompts exceed ARG_MAX and quoting JSON
" on a command line is a bug farm.
let s:msgs = substitute(s:argv[index(s:argv, '--messages') + 1], '^file://', '', '')
let s:sys = substitute(s:argv[index(s:argv, '--system') + 1], '^file://', '', '')
let s:cfg = substitute(s:argv[index(s:argv, '--inference-config') + 1],
      \ '^file://', '', '')
call s:ok(filereadable(s:msgs), 'messages are passed by file:// reference')
call s:eq(json_decode(join(readfile(s:msgs), '')),
      \ [{'role': 'user', 'content': [{'text': 'USER'}]}],
      \ 'messages carry the user turn in converse shape')
call s:eq(json_decode(join(readfile(s:sys), '')), [{'text': 'SYS'}],
      \ 'system prompt is sent as a converse system block')
call s:eq(json_decode(join(readfile(s:cfg), '')).maxTokens, 8192,
      \ 'inference config carries maxTokens')
call s:ok(!has_key(json_decode(join(readfile(s:cfg), '')), 'temperature'),
      \ 'temperature is omitted by default: newer models reject it')
call s:eq(sort(copy(s:req.cleanup)), sort([s:msgs, s:sys, s:cfg]),
      \ 'request declares its temp files for cleanup')

let g:air_max_tokens = 100
let g:air_temperature = 0.7
let g:air_top_p = 0.9
let s:cfg2 = air#backend#bedrock#inference_config()
call s:eq(s:cfg2.maxTokens, 100, 'g:air_max_tokens is honoured')
call s:eq(s:cfg2.temperature, 0.7, 'g:air_temperature is honoured when set')
call s:eq(s:cfg2.topP, 0.9, 'g:air_top_p is honoured when set')
unlet g:air_max_tokens g:air_temperature g:air_top_p

let s:cfg3 = air#backend#bedrock#inference_config()
call s:eq(keys(s:cfg3), ['maxTokens'],
      \ 'only maxTokens is sent when nothing else is configured')

let g:air_temperature = 0
call s:eq(air#backend#bedrock#inference_config().temperature, 0,
      \ 'an explicit temperature of 0 is still sent')
unlet g:air_temperature

let g:air_inference_config = {'maxTokens': 42, 'stopSequences': ['X']}
call s:eq(air#backend#bedrock#inference_config().maxTokens, 42,
      \ 'g:air_inference_config overrides individual settings')
call s:eq(air#backend#bedrock#inference_config().stopSequences, ['X'],
      \ 'g:air_inference_config can add arbitrary fields')
unlet g:air_inference_config

let g:air_aws_profile = 'work'
let g:air_aws_region = 'us-west-2'
let s:argv2 = air#backend#bedrock#request(s:payload, {}).argv
call s:eq(s:argv2[1 : 4], ['--profile', 'work', '--region', 'us-west-2'],
      \ 'profile and region precede the service name')
unlet g:air_aws_profile g:air_aws_region

let g:air_aws_args = ['--debug']
call s:ok(index(air#backend#bedrock#request(s:payload, {}).argv, '--debug') >= 0,
      \ 'extra aws args are forwarded (R7.7)')
unlet g:air_aws_args

" --- response parsing ---

let s:ok_body = json_encode({'output': {'message': {'role': 'assistant',
      \ 'content': [{'text': "revised\nlines"}]}},
      \ 'stopReason': 'end_turn', 'usage': {'inputTokens': 10}})
let s:parsed = air#backend#bedrock#parse({'status': 0, 'stdout': s:ok_body,
      \ 'stderr': ''})
call s:ok(s:parsed.ok, 'a converse response parses')
call s:eq(s:parsed.text, "revised\nlines", 'text blocks are extracted')
call s:eq(s:parsed.warning, '', 'end_turn produces no warning')

let s:multi = json_encode({'output': {'message': {'content': [
      \ {'reasoningContent': {'reasoningText': {'text': 'thinking'}}},
      \ {'text': 'part one '}, {'text': 'part two'}]}},
      \ 'stopReason': 'end_turn'})
call s:eq(air#backend#bedrock#parse({'status': 0, 'stdout': s:multi,
      \ 'stderr': ''}).text, 'part one part two',
      \ 'text blocks are joined and reasoning blocks skipped')

let s:trunc = json_encode({'output': {'message': {'content': [{'text': 'cut'}]}},
      \ 'stopReason': 'max_tokens'})
let s:parsed = air#backend#bedrock#parse({'status': 0, 'stdout': s:trunc,
      \ 'stderr': ''})
call s:ok(s:parsed.ok, 'a truncated response still parses')
call s:ok(s:parsed.warning =~# 'truncated',
      \ 'max_tokens warns that the revision is truncated')
call s:ok(s:parsed.warning =~# 'g:air_max_tokens', 'truncation warning is actionable')

call s:ok(!air#backend#bedrock#parse({'status': 0, 'stdout': '', 'stderr': ''}).ok,
      \ 'empty stdout is a failure')
call s:ok(!air#backend#bedrock#parse({'status': 0, 'stdout': 'not json',
      \ 'stderr': ''}).ok, 'unparseable stdout is a failure')
call s:ok(air#backend#bedrock#parse({'status': 0, 'stdout': 'not json',
      \ 'stderr': ''}).error =~# 'JSON', 'JSON failure says so')

let s:no_text = json_encode({'output': {'message': {'content': [
      \ {'toolUse': {'name': 'x'}}]}}, 'stopReason': 'tool_use'})
call s:ok(!air#backend#bedrock#parse({'status': 0, 'stdout': s:no_text,
      \ 'stderr': ''}).ok, 'a response with no text block is a failure')

let s:err_body = json_encode({'message': 'The security token included in the '
      \ . 'request is invalid'})
let s:parsed = air#backend#bedrock#parse({'status': 0, 'stdout': s:err_body,
      \ 'stderr': ''})
call s:ok(!s:parsed.ok, 'a JSON error body with exit 0 is a failure')
call s:ok(s:parsed.error =~# 'bedrock:', 'bedrock error bodies are labelled')

" Preserve the provider's error detail without matching error phrases.
for s:detail in ['Unable to locate credentials', 'AccessDeniedException',
      \ 'ValidationException: bad model', 'a new provider error']
  let s:parsed = air#backend#bedrock#parse({'status': 254, 'stdout': '',
        \ 'stderr': s:detail})
  call s:ok(!s:parsed.ok, 'AWS failures are rejected')
  call s:eq(s:parsed.error, 'aws failed: ' . s:detail,
        \ 'AWS error detail is preserved')
endfor

call s:eq(air#backend#bedrock#parse({'status': 1, 'stdout': '',
      \ 'stderr': ''}).error, 'aws failed: exit status 1',
      \ 'a silent non-zero exit still reports the status')

" --- end to end through the dispatcher, with a stub aws ---

let s:stub = tempname()
call writefile(['#!/bin/sh', "cat <<'JSON'", s:ok_body, 'JSON'], s:stub)
call setfperm(s:stub, 'rwxr-xr-x')
let g:air_aws_cmd = s:stub
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(s:result.ok, 'bedrock backend round-trips through the dispatcher')
call s:eq(s:result.text, "revised\nlines", 'revised text reaches the caller')
call delete(s:stub)

" A failing aws, to prove the error detail survives the sync path: system()
" folds stderr into stdout, so the dispatcher has to hand it back as stderr.
let s:failing = tempname()
call writefile(['#!/bin/sh',
      \ 'echo "An error occurred (ValidationException) when calling the '
      \ . 'Converse operation: bad model" 1>&2',
      \ 'exit 254'], s:failing)
call setfperm(s:failing, 'rwxr-xr-x')
let g:air_aws_cmd = s:failing
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(!s:result.ok, 'a failing aws is reported as a failure')
call s:ok(s:result.error =~# 'ValidationException',
      \ 'the AWS error detail survives the sync path')

" The async path keeps the streams separate on its own.
let g:air_async = 1
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
let s:waited = 0
while empty(s:result) && s:waited < 300
  sleep 10m
  let s:waited += 1
endwhile
let g:air_async = 0
call s:ok(!empty(s:result), 'async request completes (R7.18)')
call s:ok(get(s:result, 'ok', 1) == 0, 'async failure is reported')
call s:ok(get(s:result, 'error', '') =~# 'ValidationException',
      \ 'async stderr reaches the backend error mapping')
call delete(s:failing)

unlet g:air_aws_cmd
unlet g:air_model

" ======================================================= backend: openai ====

call s:say('--- backend: openai ---')

call s:ok(index(air#backend#available(), 'openai') >= 0,
      \ 'openai is discovered on the runtimepath')

let s:saved_key = $OPENAI_API_KEY
let $OPENAI_API_KEY = ''

let g:air_curl_cmd = 'definitely-not-a-real-binary-xyz'
call s:ok(air#backend#openai#check() =~# 'not found in \$PATH',
      \ 'missing curl is reported (R7.3)')
call s:ok(air#backend#openai#check() =~# 'g:air_curl_cmd',
      \ 'curl error suggests the fix')
let g:air_curl_cmd = 'sh'
call s:ok(air#backend#openai#check() =~# '\$OPENAI_API_KEY is not set',
      \ 'an unset API key is reported before spawning curl')
let $OPENAI_API_KEY = 'sk-test-secret'
call s:eq(air#backend#openai#check(), '',
      \ 'check passes with curl present and a key exported')
let g:air_openai_api_key_env = 'bad name'
call s:ok(air#backend#openai#check() =~# 'environment variable name',
      \ 'an invalid key variable name is rejected')
unlet g:air_openai_api_key_env
let g:air_openai_model = ''
call s:ok(air#backend#openai#check() =~# 'no model set',
      \ "g:air_openai_model = '' is reported")
unlet g:air_openai_model

call s:eq(air#backend#openai#model(), 'gpt-6-luna',
      \ 'gpt-6-luna is the default model')
call s:eq(air#backend#openai#reasoning_effort(), 'low',
      \ 'low is the default reasoning effort')
let g:air_model = 'us.anthropic.some-bedrock-id'
call s:eq(air#backend#openai#model(), 'gpt-6-luna',
      \ 'the Bedrock g:air_model is not sent to openai')
unlet g:air_model
let g:air_openai_model = 'gpt-test'
call s:eq(air#backend#openai#model(), 'gpt-test', 'g:air_openai_model is used')

let s:req = air#backend#openai#request(s:payload, {})
let s:argv = s:req.argv
call s:eq(s:argv[0 : 1], ['sh', '-q'], 'curl runs with ~/.curlrc ignored')
call s:eq(s:argv[-1], 'https://api.openai.com/v1/responses',
      \ 'the Responses API is the endpoint')
call s:ok(join(s:argv) =~# '--data-binary @-', 'the body is read from stdin')
call s:ok(index(s:argv, '--fail-with-body') >= 0,
      \ 'HTTP errors fail while keeping the error body')
call s:ok(join(s:argv) =~# '--variable %OPENAI_API_KEY',
      \ 'curl imports the key from the environment itself')
call s:ok(index(s:argv, 'Authorization: Bearer {{OPENAI_API_KEY}}') >= 0,
      \ 'the key is expanded by curl into the Authorization header')
call s:ok(join(s:argv) . s:req.stdin !~# 'sk-test-secret',
      \ 'the API key never appears in argv or the body')
call s:ok(empty(get(s:req, 'cleanup', [])) && empty(get(s:req, 'cleanup_dirs', [])),
      \ 'no temp files are written')
call s:ok(join(s:argv) =~# '--max-time 120 ',
      \ 'curl is bounded by g:air_timeout, even on the sync transport (R7.19)')
let g:air_timeout = 0
call s:ok(index(air#backend#openai#request(s:payload, {}).argv, '--max-time') < 0,
      \ 'g:air_timeout = 0 leaves curl unbounded')
unlet g:air_timeout

let s:body = json_decode(s:req.stdin)
call s:eq(s:body.model, 'gpt-test', 'the model is sent')
call s:eq(s:body.instructions, 'SYS', 'the system prompt is sent as instructions')
call s:eq(s:body.input, 'USER', 'the user payload is sent as input')
call s:eq(s:body.store, v:false, 'responses are not stored')
call s:eq(s:body.reasoning, {'effort': 'low'}, 'the reasoning effort is sent')
unlet g:air_openai_model

let g:air_openai_reasoning_effort = ''
call s:ok(!has_key(air#backend#openai#body(s:payload), 'reasoning'),
      \ "g:air_openai_reasoning_effort = '' leaves the effort to the API")
unlet g:air_openai_reasoning_effort

call s:eq(s:body.max_output_tokens, 8192, 'OpenAI output limit defaults to 8192')
let g:air_openai_max_output_tokens = 500
let g:air_openai_params = {'store': v:true, 'tools': [{'type': 'web_search'}],
      \ 'model': 'ignored', 'instructions': 'ignored', 'input': 'ignored'}
let s:body = air#backend#openai#body(s:payload)
call s:eq(s:body.max_output_tokens, 500, 'explicit OpenAI output limit is used')
call s:eq(s:body.store, v:false, 'legacy params cannot enable storage')
call s:ok(!has_key(s:body, 'tools'), 'legacy params cannot enable tools')
call s:eq(s:body.model, 'gpt-6-luna', 'legacy params cannot change the model')
call s:eq(s:body.instructions, 'SYS', 'legacy params cannot change instructions')
call s:eq(s:body.input, 'USER', 'legacy params cannot change input')
unlet g:air_openai_params g:air_openai_max_output_tokens

let g:air_openai_base_url = 'http://localhost:8080/v1/'
let g:air_openai_api_key_env = 'MY_KEY'
let g:air_curl_args = ['--proxy', 'http://p:3128']
let s:argv2 = air#backend#openai#request(s:payload, {}).argv
call s:eq(s:argv2[-1], 'http://localhost:8080/v1/responses',
      \ 'g:air_openai_base_url is honoured, trailing slash and all')
call s:ok(index(s:argv2, 'Authorization: Bearer {{MY_KEY}}') >= 0,
      \ 'g:air_openai_api_key_env names the key variable')
call s:eq(s:argv2[-3 : -2], ['--proxy', 'http://p:3128'],
      \ 'extra curl args are forwarded before the URL (R7.7)')
unlet g:air_openai_base_url g:air_openai_api_key_env g:air_curl_args

" --- parse() ---

let s:oa_ok = json_encode({'status': 'completed', 'error': v:null,
      \ 'output': [
      \   {'type': 'reasoning', 'summary': []},
      \   {'type': 'message', 'role': 'assistant', 'content': [
      \     {'type': 'output_text', 'text': "revised\nlines", 'annotations': []}]}],
      \ 'usage': {'input_tokens': 10, 'output_tokens': 2}})
let s:parsed = air#backend#openai#parse({'status': 0, 'stdout': s:oa_ok,
      \ 'stderr': ''})
call s:ok(s:parsed.ok, 'a completed response parses')
call s:eq(s:parsed.text, "revised\nlines", 'output_text is returned')
call s:eq(s:parsed.warning, '', 'a completed response has no warning')
call s:eq(s:parsed.usage.output_tokens, 2, 'usage is reported')

call s:eq(air#backend#openai#parse({'status': 0, 'stdout': json_encode({
      \ 'status': 'completed', 'output': [{'type': 'message', 'content': [
      \   {'type': 'output_text', 'text': 'part one '},
      \   {'type': 'output_text', 'text': 'part two'}]}]}),
      \ 'stderr': ''}).text, 'part one part two', 'text parts are joined')

let s:parsed = air#backend#openai#parse({'status': 0, 'stdout': json_encode({
      \ 'status': 'incomplete',
      \ 'incomplete_details': {'reason': 'max_output_tokens'},
      \ 'output': [{'type': 'message', 'content': [
      \   {'type': 'output_text', 'text': 'cut'}]}]}), 'stderr': ''})
call s:ok(s:parsed.ok, 'a truncated response still parses')
call s:ok(s:parsed.warning =~# 'truncated',
      \ 'max_output_tokens warns that the revision is truncated (R7.15)')

call s:ok(!air#backend#openai#parse({'status': 0, 'stdout': '', 'stderr': ''}).ok,
      \ 'empty output fails')
call s:ok(air#backend#openai#parse({'status': 0, 'stdout': 'not json',
      \ 'stderr': ''}).error =~# 'JSON', 'non-JSON output fails clearly')
call s:ok(air#backend#openai#parse({'status': 0, 'stdout': json_encode({
      \ 'status': 'incomplete', 'incomplete_details': {'reason': 'max_output_tokens'},
      \ 'output': [{'type': 'reasoning'}]}), 'stderr': ''}).error
      \ =~# 'no text (status: incomplete, max_output_tokens)',
      \ 'a response spent entirely on reasoning fails with the reason')
call s:ok(air#backend#openai#parse({'status': 0, 'stdout': json_encode({
      \ 'status': 'completed', 'output': [{'type': 'message', 'content': [
      \   {'type': 'refusal', 'refusal': 'no can do'}]}]}),
      \ 'stderr': ''}).error =~# 'refused: no can do', 'a refusal is reported')
call s:ok(air#backend#openai#parse({'status': 0, 'stdout': json_encode({
      \ 'status': 'failed', 'error': {'code': 'server_error',
      \ 'message': 'boom'}, 'output': []}), 'stderr': ''}).error
      \ ==# 'openai: boom (server_error)', 'a failed response reports its error')

let s:oa_401 = json_encode({'error': {'message': 'Incorrect API key provided: '
      \ . 'sk-x.', 'type': 'invalid_request_error', 'code': 'invalid_api_key'},
      \ 'status': 401})
let s:parsed = air#backend#openai#parse({'status': 22, 'stdout': s:oa_401,
      \ 'stderr': 'curl: (22) The requested URL returned error: 401'})
call s:ok(!s:parsed.ok, 'an HTTP error is a failure')
call s:ok(s:parsed.error =~# '^openai: Incorrect API key',
      \ 'the API error message is surfaced')
call s:ok(air#backend#openai#parse({'status': 22,
      \ 'stdout': "curl: (22) The requested URL returned error: 401\n" . s:oa_401,
      \ 'stderr': ''}).error =~# 'Incorrect API key',
      \ 'the error body is found when stderr is folded into stdout')

for s:detail in ['Not Found', 'invalid key', 'a new provider error']
  let s:parsed = air#backend#openai#parse({'status': 22,
        \ 'stdout': json_encode({'error': {'message': s:detail}}), 'stderr': ''})
  call s:eq(s:parsed.error, 'openai: ' . s:detail,
        \ 'OpenAI error detail is preserved')
endfor
let s:parsed = air#backend#openai#parse({'status': 28, 'stdout': '',
      \ 'stderr': 'curl: (28) Operation timed out'})
call s:eq(s:parsed.error, 'curl failed: curl: (28) Operation timed out',
      \ 'curl error detail is preserved')

" --- end to end through the dispatcher, with a stub curl ---

let g:air_backend_name = 'openai'
let s:seen = tempname()
let s:stub = tempname()
call writefile(['#!/bin/sh',
      \ 'cat > ' . shellescape(s:seen),
      \ "cat <<'JSON'", s:oa_ok, 'JSON'], s:stub)
call setfperm(s:stub, 'rwxr-xr-x')
let g:air_curl_cmd = s:stub
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
call s:ok(s:result.ok, 'openai backend round-trips through the dispatcher')
call s:eq(s:result.text, "revised\nlines", 'openai text reaches the caller')
call s:eq(json_decode(join(readfile(s:seen), "\n")).input, 'USER',
      \ 'the stub received the request body on stdin')

call delete(s:seen)
let g:air_async = 1
let s:result = {}
call air#backend#run(s:payload, {}, function('Capture'))
let s:waited = 0
while empty(s:result) && s:waited < 300
  sleep 10m
  let s:waited += 1
endwhile
let g:air_async = 0
call s:ok(get(s:result, 'ok', 0), 'async openai request completes (R7.18)')
call s:eq(json_decode(join(readfile(s:seen), "\n")).instructions, 'SYS',
      \ 'the async path delivers the body on stdin')
call delete(s:stub)
call delete(s:seen)

unlet g:air_curl_cmd
unlet g:air_backend_name
let $OPENAI_API_KEY = s:saved_key

let g:Air_backend = s:saved_backend

call s:ok(!air#backend#abort(), 'abort with no job in flight is a no-op')

" Status lines must fit the command line, or they end in a hit-enter prompt.
let s:long = 'start ' . repeat('x', 3 * &columns) . ' end'
call air#warn(s:long)
let s:shown = split(execute('messages'), "\n")[-1]
call s:ok(strdisplaywidth(s:shown) < &columns,
      \ 'a long warning is shortened to fit the command line')
call s:ok(s:shown =~# '^air: start x\+\.\.\.x\+ end$',
      \ 'a shortened message keeps its start and end')
call s:ok(air#log#entries()[-1] =~# 'WARN: ' . s:long . '$',
      \ ':AirLog keeps the full message')

" ------------------------------------------------------------------ hooks ----

call s:say('--- hooks ---')

let s:saved = g:Air_backend
unlet g:Air_backend
call s:ok(air#hook('backend') is v:null, 'unset hook resolves to v:null')

" String form works around E704 for users who prefer the lowercase prefix.
let g:air_backend = 'FakeBackend'
call s:ok(type(air#hook('backend')) == type(function('tr')),
      \ 'string hook resolves to a Funcref (E704 workaround)')
let g:air_fake_prompts = []
let g:air_fake_reply = 'X'
let s:result = {}
call air#backend#run({'system': 'S', 'user': 'U'}, {}, function('Capture'))
call s:eq(len(g:air_fake_prompts), 1, 'string-named backend hook is honoured')
unlet g:air_backend

let g:Air_backend = s:saved
call s:ok(type(air#hook('backend')) == type(function('tr')),
      \ 'capitalized Funcref hook is honoured')

" =============================================================== summary ====

call s:say('')
if s:fails > 0
  call s:say(s:fails . ' test(s) failed')
  cquit
endif
call s:say('all tests passed')
qall!
