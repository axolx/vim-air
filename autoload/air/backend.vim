" vim-air — backend dispatcher and process runner (§7).
"
" Backends are pluggable. A backend named "foo" lives in
" autoload/air/backend/foo.vim and implements three functions:
"
"   air#backend#foo#check() -> string
"       '' when the backend is usable, otherwise a user-facing reason
"       (missing executable, unset model, ...). Called before every request.
"
"   air#backend#foo#request({payload}, {opts}) -> dict
"       Describes the subprocess to run. Keys:
"         argv         (list, required) command and arguments
"         stdin        (string, optional) text to write to stdin
"         cleanup      (list, optional) files to delete when done
"         cleanup_dirs (list, optional) directories to delete when done
"       {payload} is {'system': ..., 'user': ...}.
"       {opts} carries per-request overrides such as {'model': ...}.
"
"   air#backend#foo#parse({result}) -> dict
"       Turns the finished process into a result. {result} is
"       {'status': exit code, 'stdout': ..., 'stderr': ...}.
"       Returns {'ok': 0|1, 'text': ..., 'error': ..., 'warning': ...}.
"       Backends own their own error mapping, so provider-specific failure
"       messages stay out of this file.
"
" Select one with g:air_backend_name. Everything below is provider-agnostic:
" argv execution, async/sync, timeouts, aborting, temp-file cleanup, logging.

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

let s:job = v:null
let s:timer = -1
let s:ctx = {}

let s:default_backend = 'bedrock'

function! air#backend#name() abort
  return air#get('backend_name', s:default_backend)
endfunction

function! air#backend#available() abort
  let names = []
  for path in globpath(&runtimepath, 'autoload/air/backend/*.vim', 0, 1)
    call add(names, fnamemodify(path, ':t:r'))
  endfor
  return air#util#uniq(sort(names))
endfunction

function! s:fn(name, method) abort
  return 'air#backend#' . a:name . '#' . a:method
endfunction

" Resolve a backend, verifying it implements the interface.
function! air#backend#resolve(name) abort
  if a:name !~# '^\w\+$'
    throw 'air: invalid backend name "' . a:name . '"'
  endif

  " exists('*autoload#fn') does not trigger autoloading, so source the file.
  execute 'runtime! autoload/air/backend/' . a:name . '.vim'

  let missing = []
  for method in ['check', 'request', 'parse']
    if !exists('*' . s:fn(a:name, method))
      call add(missing, method . '()')
    endif
  endfor

  if !empty(missing)
    let known = air#backend#available()
    if index(known, a:name) < 0
      throw 'air: unknown backend "' . a:name . '" (available: '
            \ . join(known, ', ') . ')'
    endif
    throw 'air: backend "' . a:name . '" does not implement '
          \ . join(missing, ', ')
  endif

  return {
        \ 'name': a:name,
        \ 'check': function(s:fn(a:name, 'check')),
        \ 'request': function(s:fn(a:name, 'request')),
        \ 'parse': function(s:fn(a:name, 'parse')),
        \ }
endfunction

" a:payload is {'system': ..., 'user': ...}
" a:Cb receives {'ok': 0|1, 'text': ..., 'error': ..., 'raw': ...}
function! air#backend#run(payload, opts, Cb) abort
  " R7.7 / R10.3 — tests and alternative transports replace this one function.
  let Override = air#hook('backend')
  if Override isnot v:null
    return call(Override, [a:payload, a:opts, a:Cb])
  endif

  try
    let backend = air#backend#resolve(air#backend#name())
  catch /^air:/
    return s:fail(a:Cb, substitute(v:exception, '^air:\s*', '', ''))
  endtry

  " R7.3 — preflight, so misconfiguration is reported before spawning anything.
  let problem = call(backend.check, [])
  if !empty(problem)
    return s:fail(a:Cb, problem)
  endif

  if s:job isnot v:null
    return s:fail(a:Cb, 'a request is already in flight (:AirAbort to cancel)')
  endif

  try
    let request = call(backend.request, [a:payload, a:opts])
  catch
    return s:fail(a:Cb, 'backend ' . backend.name . ' failed to build a request: '
          \ . v:exception)
  endtry

  let request = extend({'argv': [], 'stdin': '', 'cleanup': [],
        \ 'cleanup_dirs': []}, request)

  if empty(request.argv)
    call s:cleanup(request)
    return s:fail(a:Cb, 'backend ' . backend.name . ' produced no command')
  endif

  call air#log#add('exec: ' . join(request.argv, ' '))

  if s:async_available()
    call s:run_async(backend, request, a:Cb)
  else
    call s:run_sync(backend, request, a:Cb)
  endif
endfunction

function! s:fail(Cb, error) abort
  return call(a:Cb, [{'ok': 0, 'text': '', 'raw': '', 'error': a:error}])
endfunction

function! s:async_available() abort
  if !air#get('async', 1)
    return 0
  endif
  return has('nvim') ? exists('*jobstart') : (has('job') && has('channel'))
endfunction

" ------------------------------------------------------------------ sync -----

" R7.18 — blocking fallback when jobs are unavailable.
function! s:run_sync(backend, request, Cb) abort
  let cmd = join(map(copy(a:request.argv), 'shellescape(v:val)'), ' ')
  let out = empty(a:request.stdin) ? system(cmd) : system(cmd, a:request.stdin)
  " system() cannot separate the streams: 'shellredir' folds stderr into the
  " output. On failure that text is almost certainly the error message, so pass
  " it as stderr as well, where a backend's error mapping expects it.
  let err = v:shell_error != 0 ? out : ''
  call s:finish(a:backend, a:request, a:Cb, v:shell_error, out, err)
endfunction

" ----------------------------------------------------------------- async -----

function! s:run_async(backend, request, Cb) abort
  let s:ctx = {'out': [], 'err': [], 'cb': a:Cb, 'done': 0,
        \ 'backend': a:backend, 'request': a:request}

  if has('nvim')
    let s:job = jobstart(a:request.argv, {
          \ 'on_stdout': function('s:nvim_out'),
          \ 'on_stderr': function('s:nvim_err'),
          \ 'on_exit':   function('s:nvim_exit'),
          \ 'stdout_buffered': v:true,
          \ 'stderr_buffered': v:true,
          \ })
    if s:job <= 0
      let s:job = v:null
      return s:finish(a:backend, a:request, a:Cb, 1, '',
            \ 'failed to start ' . a:request.argv[0])
    endif
    if !empty(a:request.stdin)
      call chansend(s:job, a:request.stdin)
    endif
    silent! call chanclose(s:job, 'stdin')
  else
    let options = {
          \ 'out_mode': 'raw',
          \ 'err_mode': 'raw',
          \ 'out_cb':   function('s:vim_out'),
          \ 'err_cb':   function('s:vim_err'),
          \ 'exit_cb':  function('s:vim_exit'),
          \ }
    if empty(a:request.stdin)
      let options.in_io = 'null'
    endif
    let s:job = job_start(a:request.argv, options)
    if job_status(s:job) !=# 'run'
      let s:job = v:null
      return s:finish(a:backend, a:request, a:Cb, 1, '',
            \ 'failed to start ' . a:request.argv[0])
    endif
    if !empty(a:request.stdin)
      call ch_sendraw(s:job, a:request.stdin)
      silent! call ch_close_in(s:job)
    endif
  endif

  " R7.19 — bounded wait.
  let timeout = air#get('timeout', 120)
  if timeout > 0
    let s:timer = timer_start(timeout * 1000, function('s:on_timeout'))
  endif
endfunction

function! s:vim_out(ch, msg) abort
  call add(s:ctx.out, a:msg)
endfunction

function! s:vim_err(ch, msg) abort
  call add(s:ctx.err, a:msg)
endfunction

function! s:vim_exit(job, status) abort
  call s:async_finish(a:status)
endfunction

function! s:nvim_out(id, data, event) abort
  call add(s:ctx.out, join(a:data, "\n"))
endfunction

function! s:nvim_err(id, data, event) abort
  call add(s:ctx.err, join(a:data, "\n"))
endfunction

function! s:nvim_exit(id, status, event) abort
  call s:async_finish(a:status)
endfunction

function! s:async_finish(status) abort
  if get(s:ctx, 'done', 1)
    return
  endif
  let s:ctx.done = 1
  call s:cancel_timer()
  let s:job = v:null
  call s:finish(s:ctx.backend, s:ctx.request, s:ctx.cb, a:status,
        \ join(s:ctx.out, ''), join(s:ctx.err, ''))
endfunction

function! s:on_timeout(timer) abort
  if s:job is v:null
    return
  endif
  call air#backend#abort()
  call air#error(air#backend#name() . ' timed out after '
        \ . air#get('timeout', 120) . 's')
endfunction

function! s:cancel_timer() abort
  if s:timer != -1
    silent! call timer_stop(s:timer)
    let s:timer = -1
  endif
endfunction

" R4.8 — cancel an in-flight request.
function! air#backend#abort() abort
  if s:job is v:null
    return 0
  endif
  if has('nvim')
    silent! call jobstop(s:job)
  else
    silent! call job_stop(s:job)
  endif
  let s:job = v:null
  let s:ctx.done = 1
  call s:cancel_timer()
  call s:cleanup(get(s:ctx, 'request', {}))
  return 1
endfunction

function! s:cleanup(request) abort
  if empty(a:request) || !air#get('cleanup_tempfiles', 1)
    return
  endif
  for path in get(a:request, 'cleanup', [])
    silent! call delete(path)
  endfor
  for dir in get(a:request, 'cleanup_dirs', [])
    silent! call delete(dir, 'd')
  endfor
endfunction

" ---------------------------------------------------------------- result -----

function! s:finish(backend, request, Cb, status, out, err) abort
  call s:cleanup(a:request)

  let raw = a:err ==# a:out ? a:out
        \ : a:out . (empty(a:err) ? '' : "\n[stderr]\n" . a:err)
  let result = {'status': a:status,
        \ 'stdout': air#text#strip_ansi(a:out),
        \ 'stderr': air#text#strip_ansi(a:err)}

  let parsed = extend({'ok': 0, 'text': '', 'error': '', 'warning': ''},
        \ call(a:backend.parse, [result]))

  if !parsed.ok
    return call(a:Cb, [{'ok': 0, 'text': '', 'raw': raw,
          \ 'error': !empty(parsed.error) ? parsed.error
          \ : a:backend.name . ' failed (exit ' . a:status . ')'}])
  endif

  let text = parsed.text
  let Filter = air#hook('output_filter')
  if Filter isnot v:null
    let text = call(Filter, [text])
  endif

  if !empty(parsed.warning)
    call air#warn(parsed.warning)
  endif

  return call(a:Cb, [{'ok': 1, 'text': text, 'raw': raw, 'error': '',
        \ 'warning': parsed.warning}])
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
