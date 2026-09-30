" vim-air — OpenAI API backend, one Responses API call through `curl`.
"
" Implements the backend interface documented in autoload/air/backend.vim.
" Everything OpenAI-specific lives here: the request body, response parsing
" and error mapping. A revision is a single HTTP request, with no agent loop,
" tools or session state, so it is billed to the API key's account.
"
" vim-air never reads the API key: curl imports it from the environment
" (--variable %NAME) and expands it into the Authorization header, so it never
" appears in argv, in a temp file, or in :AirLog.

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

" Revisions are short, single-turn edits: a fast model at low effort keeps the
" wait short. The API default effort is medium; an explicit '' omits it.
let s:default_model = 'gpt-6-luna'
let s:default_effort = 'low'
let s:default_base_url = 'https://api.openai.com/v1'

function! air#backend#openai#cmd() abort
  return air#get('curl_cmd', 'curl')
endfunction

" R7.24 — per-call model wins, then g:air_openai_model, then the built-in
" default. g:air_model is not consulted: it holds a Bedrock model ID for most
" users.
function! air#backend#openai#model(opts) abort
  let model = get(a:opts, 'model', '')
  return !empty(model) ? model : air#get('openai_model', s:default_model)
endfunction

function! air#backend#openai#reasoning_effort() abort
  return air#get('openai_reasoning_effort', s:default_effort)
endfunction

function! air#backend#openai#key_env() abort
  return air#get('openai_api_key_env', 'OPENAI_API_KEY')
endfunction

function! air#backend#openai#url() abort
  let base = air#get('openai_base_url', s:default_base_url)
  return substitute(base, '/\+$', '', '') . '/responses'
endfunction

" ----------------------------------------------------------------- check -----

function! air#backend#openai#check() abort
  let cmd = air#backend#openai#cmd()
  if !executable(cmd)
    return cmd . ' not found in $PATH — install curl 8.3+, or set g:air_curl_cmd'
  endif

  let env = air#backend#openai#key_env()
  if env !~# '^\h\w*$'
    return 'g:air_openai_api_key_env must be an environment variable name, '
          \ . 'not "' . env . '"'
  endif
  if !exists('$' . env) || empty(eval('$' . env))
    return '$' . env . ' is not set — export your OpenAI API key before '
          \ . 'starting Vim (see :help air-backend-openai)'
  endif

  if empty(air#backend#openai#model({}))
    return 'no model set — e.g. let g:air_openai_model = '
          \ . "'" . s:default_model . "'"
  endif

  return ''
endfunction

" --------------------------------------------------------------- request -----

function! air#backend#openai#body(payload, opts) abort
  let model = air#backend#openai#model(a:opts)
  if empty(model)
    throw 'air: no OpenAI model set (g:air_openai_model)'
  endif

  " store: revisions are one-shot, so nothing is kept for later retrieval.
  let body = {
        \ 'model': model,
        \ 'instructions': a:payload.system,
        \ 'input': a:payload.user,
        \ 'store': v:false,
        \ }

  let effort = air#backend#openai#reasoning_effort()
  if !empty(effort)
    let body.reasoning = {'effort': effort}
  endif

  " Escape hatch for anything else the Responses API accepts.
  return extend(body, air#get('openai_params', {}))
endfunction

" R7.21 / R7.23 — POST /v1/responses. The body goes over stdin: documents
" routinely exceed ARG_MAX, and stdin needs no temp file.
function! air#backend#openai#request(payload, opts) abort
  let env = air#backend#openai#key_env()

  " -q first, so a ~/.curlrc cannot add -i, -v or --write-out to the output.
  let argv = [air#backend#openai#cmd(), '-q']
  let argv += ['--silent', '--show-error', '--fail-with-body']
  let argv += ['--variable', '%' . env]
  let argv += ['--expand-header', 'Authorization: Bearer {{' . env . '}}']
  let argv += ['--header', 'Content-Type: application/json']
  let argv += ['--data-binary', '@-']
  " R7.19 — curl has no overall time limit of its own, and the dispatcher's
  " timer only covers the async transport, so bound the request here too.
  let timeout = air#get('timeout', 120)
  if timeout > 0
    let argv += ['--max-time', string(timeout)]
  endif
  " R7.24 — forward-compatibility escape hatch (proxies, org headers, ...).
  let argv += air#get('curl_args', [])
  let argv += [air#backend#openai#url()]

  return {
        \ 'argv': argv,
        \ 'stdin': json_encode(air#backend#openai#body(a:payload, a:opts)),
        \ }
endfunction

" ----------------------------------------------------------------- parse -----

" Response shape:
"   {"status":"completed","error":null,"incomplete_details":null,
"    "output":[{"type":"reasoning",...},
"              {"type":"message","content":[{"type":"output_text","text":"..."}]}],
"    "usage":{...}}
" HTTP errors arrive (thanks to --fail-with-body) as a non-zero exit with
"   {"error":{"message":"...","type":"...","code":"..."}}
" on stdout.
function! air#backend#openai#parse(result) abort
  let resp = s:decode(a:result.stdout)

  if a:result.status != 0
    let detail = s:error_message(resp)
    if !empty(detail)
      return {'ok': 0, 'text': '', 'error': 'openai: ' . s:humanize(detail)}
    endif
    return {'ok': 0, 'text': '',
          \ 'error': 'curl failed: ' . s:humanize(s:last_line(a:result.stderr,
          \ 'exit status ' . a:result.status))}
  endif

  if type(resp) != type({})
    return {'ok': 0, 'text': '', 'error': empty(a:result.stdout)
          \ ? 'openai returned empty output'
          \ : 'could not parse the openai response as JSON (see :AirLog)'}
  endif

  let detail = s:error_message(resp)
  if !empty(detail)
    return {'ok': 0, 'text': '', 'error': 'openai: ' . s:humanize(detail)}
  endif

  let output = get(resp, 'output', [])
  if type(output) != type([])
    return {'ok': 0, 'text': '', 'error': 'no output in the openai response'}
  endif

  " Keep output_text parts of message items; skip reasoning and tool items.
  let parts = []
  let refusal = ''
  for item in output
    if type(item) != type({}) || get(item, 'type', '') !=# 'message'
      continue
    endif
    let content = get(item, 'content', [])
    for part in type(content) == type([]) ? content : []
      if type(part) != type({})
        continue
      endif
      if get(part, 'type', '') ==# 'output_text'
        call add(parts, get(part, 'text', ''))
      elseif get(part, 'type', '') ==# 'refusal'
        let refusal = get(part, 'refusal', '')
      endif
    endfor
  endfor

  let status = get(resp, 'status', '')
  let details = get(resp, 'incomplete_details', {})
  let reason = type(details) == type({}) ? get(details, 'reason', '') : ''

  if empty(parts) || empty(join(parts, ''))
    if !empty(refusal)
      return {'ok': 0, 'text': '', 'error': 'the model refused: ' . refusal}
    endif
    return {'ok': 0, 'text': '', 'error': 'the model returned no text (status: '
          \ . status . (empty(reason) ? '' : ', ' . reason) . ')'}
  endif

  " A truncated revision still looks like a legitimate diff, so flag it.
  let warning = ''
  if status ==# 'incomplete'
    let warning = reason ==# 'max_output_tokens'
          \ ? 'response hit max_output_tokens and is truncated — raise it in '
          \   . 'g:air_openai_params or revise a smaller scope'
          \ : 'response is incomplete (' . reason . ') and may be truncated'
  endif

  return {'ok': 1, 'text': join(parts, ''), 'error': '', 'warning': warning,
        \ 'stop_reason': status, 'usage': get(resp, 'usage', {})}
endfunction

" The sync transport folds stderr into stdout, so the body can follow a
" "curl: (22) ..." line: decode from the first line that opens an object.
function! s:decode(text) abort
  let raw = matchstr(a:text, '\%(^\|\n\)\s*\zs{\_.*')
  let raw = substitute(raw, '\_s*$', '', '')
  if empty(raw)
    return v:null
  endif
  try
    return json_decode(raw)
  catch
    return v:null
  endtry
endfunction

" '' unless {resp} carries an API error object.
function! s:error_message(resp) abort
  if type(a:resp) != type({})
    return ''
  endif
  let err = get(a:resp, 'error', v:null)
  if type(err) == type({})
    let msg = get(err, 'message', '')
    let code = get(err, 'code', '')
    let msg = type(msg) == type('') ? msg : string(msg)
    if type(code) == type('') && !empty(code) && stridx(msg, code) < 0
      let msg .= ' (' . code . ')'
    endif
    return !empty(msg) ? msg : string(err)
  endif
  if get(a:resp, 'status', '') ==# 'failed'
    return 'the response failed'
  endif
  return ''
endfunction

function! s:last_line(text, fallback) abort
  let lines = filter(split(a:text, "\n"),
        \ 'v:val !~# "^\\s*$\\|^curl: try ''curl --help''"')
  return empty(lines) ? a:fallback : lines[-1]
endfunction

" Turn the most common API and curl failures into something actionable.
function! s:humanize(detail) abort
  let d = a:detail
  if d =~? 'Incorrect API key\|invalid_api_key\|\<401\>\|Unauthorized'
    return d . ' — check $' . air#backend#openai#key_env()
  endif
  if d =~? 'model_not_found\|model .* does not exist\|do not have access to'
        \ . ' the model'
    return d . ' — set g:air_openai_model to a model your API key can use'
  endif
  if d =~? 'insufficient_quota\|exceeded your current quota'
    return d . ' — add credits or raise the limit on your OpenAI account'
  endif
  if d =~? 'rate limit\|rate_limit\|\<429\>\|Too Many Requests'
    return d . ' — rate limited by OpenAI; retry shortly'
  endif
  if d =~? 'reasoning.effort'
    return d . ' — this model rejects that effort: change or unset '
          \ . 'g:air_openai_reasoning_effort'
  endif
  if d =~? 'Unsupported parameter\|Unknown parameter'
    return d . ' — remove it from g:air_openai_params'
  endif
  if d =~? 'import fail\|variable expansion failure'
    return d . ' — export $' . air#backend#openai#key_env() . ' before '
          \ . 'starting Vim'
  endif
  if d =~? 'Operation timed out'
    return d . ' — raise g:air_timeout or revise a smaller scope'
  endif
  if d =~? 'option --\%(variable\|expand-header\).*unknown\|unknown option'
    return d . ' — vim-air needs curl 8.3 or newer'
  endif
  if d =~? 'Could not resolve host\|Failed to connect\|Connection refused'
        \ . '\|Connection timed out'
    return d . ' — network problem reaching ' . air#backend#openai#url()
  endif
  if d =~? 'returned error: 404'
    return d . ' — check g:air_openai_base_url'
  endif
  return d
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
