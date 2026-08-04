" vim-air — AWS Bedrock backend, invoked through the `aws` CLI.
"
" Implements the backend interface documented in autoload/air/backend.vim.
" Everything Bedrock-specific lives here: the converse request shape, model
" resolution, response parsing and AWS error mapping.

scriptencoding utf-8

let s:save_cpo = &cpoptions
set cpoptions&vim

function! air#backend#bedrock#cmd() abort
  return air#get('aws_cmd', 'aws')
endfunction

" R7.6 — per-call model wins, then g:air_model.
function! air#backend#bedrock#model(opts) abort
  let model = get(a:opts, 'model', '')
  return !empty(model) ? model : air#get('model', '')
endfunction

" ----------------------------------------------------------------- check -----

function! air#backend#bedrock#check() abort
  let cmd = air#backend#bedrock#cmd()
  if !executable(cmd)
    return cmd . ' not found in $PATH — install the AWS CLI v2, '
          \ . 'or set g:air_aws_cmd'
  endif

  " Bedrock model IDs are account- and region-specific, so there is no safe
  " default to fall back on.
  if empty(air#backend#bedrock#model({}))
    return 'no model set — e.g. let g:air_model = '
          \ . "'us.anthropic.claude-sonnet-4-20250514-v1:0' "
          \ . '(see :help g:air_model)'
  endif

  return ''
endfunction

" --------------------------------------------------------------- request -----

" Only maxTokens is sent unconditionally. Newer models (Claude Sonnet 4.5 and
" the reasoning models) reject `temperature` with a ValidationException saying
" it is deprecated, so it is omitted unless explicitly configured. Same for
" topP, which those models deprecate alongside it.
function! air#backend#bedrock#inference_config() abort
  let cfg = {'maxTokens': air#get('max_tokens', 8192)}

  let temperature = air#get('temperature', -1)
  if temperature >= 0
    let cfg.temperature = temperature
  endif

  let top_p = air#get('top_p', -1)
  if top_p >= 0
    let cfg.topP = top_p
  endif

  " Escape hatch for anything else InferenceConfiguration accepts.
  return extend(cfg, air#get('inference_config', {}))
endfunction

" R7.1 — bedrock-runtime converse: one request shape for every Bedrock model.
function! air#backend#bedrock#request(payload, opts) abort
  let model = air#backend#bedrock#model(a:opts)
  if empty(model)
    throw 'air: no Bedrock model set (g:air_model)'
  endif

  let dir = tempname()
  call mkdir(dir, 'p')
  let messages_file = dir . '/messages.json'
  let system_file = dir . '/system.json'
  let config_file = dir . '/inference.json'

  " Payloads go in files, not argv: prompts routinely exceed ARG_MAX and
  " embedding JSON in a command line invites quoting bugs.
  call writefile([json_encode([{'role': 'user',
        \ 'content': [{'text': a:payload.user}]}])], messages_file)
  call writefile([json_encode([{'text': a:payload.system}])], system_file)
  call writefile([json_encode(air#backend#bedrock#inference_config())],
        \ config_file)

  let argv = [air#backend#bedrock#cmd()]

  " Global options must precede the service name.
  let profile = air#get('aws_profile', '')
  if !empty(profile)
    let argv += ['--profile', profile]
  endif
  let region = air#get('aws_region', '')
  if !empty(region)
    let argv += ['--region', region]
  endif

  let argv += ['bedrock-runtime', 'converse']
  let argv += ['--model-id', model]
  let argv += ['--messages', 'file://' . messages_file]
  let argv += ['--system', 'file://' . system_file]
  let argv += ['--inference-config', 'file://' . config_file]
  let argv += ['--output', 'json', '--no-cli-pager']
  " R7.7 — forward-compatibility escape hatch.
  let argv += air#get('aws_args', [])

  return {
        \ 'argv': argv,
        \ 'cleanup': [messages_file, system_file, config_file],
        \ 'cleanup_dirs': [dir],
        \ }
endfunction

" ----------------------------------------------------------------- parse -----

" Converse response shape:
"   {"output":{"message":{"role":"assistant","content":[{"text":"..."}]}},
"    "stopReason":"end_turn","usage":{...},"metrics":{...}}
function! air#backend#bedrock#parse(result) abort
  " R7.9 — the AWS CLI reports auth, throttling and validation errors on
  " stderr with a non-zero exit.
  if a:result.status != 0
    return {'ok': 0, 'text': '',
          \ 'error': 'aws failed: ' . s:humanize(s:last_line(a:result.stderr,
          \ 'exit status ' . a:result.status))}
  endif

  let raw = substitute(a:result.stdout, '^\_s*\|\_s*$', '', 'g')
  if empty(raw)
    return {'ok': 0, 'text': '', 'error': 'aws returned empty output'}
  endif

  try
    let resp = json_decode(raw)
  catch
    return {'ok': 0, 'text': '',
          \ 'error': 'could not parse the aws response as JSON (see :AirLog)'}
  endtry

  if type(resp) != type({})
    return {'ok': 0, 'text': '', 'error': 'unexpected aws response shape'}
  endif

  " Some failures come back as a JSON body with a zero exit status.
  if !has_key(resp, 'output') && has_key(resp, 'message')
    return {'ok': 0, 'text': '', 'error': 'bedrock: ' . s:humanize(resp.message)}
  endif

  let content = get(get(get(resp, 'output', {}), 'message', {}), 'content', [])
  if type(content) != type([])
    return {'ok': 0, 'text': '', 'error': 'no content in the aws response'}
  endif

  " Keep text blocks; skip reasoningContent and toolUse blocks.
  let parts = []
  for block in content
    if type(block) == type({}) && has_key(block, 'text')
      call add(parts, block.text)
    endif
  endfor

  let stop = get(resp, 'stopReason', '')

  if empty(parts)
    return {'ok': 0, 'text': '',
          \ 'error': 'the model returned no text (stopReason: ' . stop . ')'}
  endif

  " A truncated revision still looks like a legitimate diff, so flag it.
  let warning = stop ==# 'max_tokens'
        \ ? 'response hit maxTokens and is truncated — raise g:air_max_tokens '
        \   . 'or revise a smaller scope'
        \ : ''

  return {'ok': 1, 'text': join(parts, ''), 'error': '', 'warning': warning,
        \ 'stop_reason': stop, 'usage': get(resp, 'usage', {})}
endfunction

function! s:last_line(text, fallback) abort
  let lines = filter(split(a:text, "\n"), 'v:val !~# "^\\s*$"')
  return empty(lines) ? a:fallback : lines[-1]
endfunction

" Turn the most common AWS failures into something actionable.
function! s:humanize(detail) abort
  let d = a:detail
  " Newer models reject inference parameters that older ones require.
  if d =~? '`\?temperature`\? is deprecated'
    return d . ' — this model rejects temperature: unset g:air_temperature '
          \ . '(and g:air_top_p)'
  endif
  if d =~? '`\?top_\?p`\? is deprecated\|topP.*not supported'
    return d . ' — this model rejects topP: unset g:air_top_p'
  endif
  if d =~? 'Unable to locate credentials\|ExpiredToken\|InvalidClientTokenId'
        \ . '\|security token included in the request is invalid'
    return d . ' — refresh your AWS credentials (aws sso login) or set '
          \ . 'g:air_aws_profile'
  endif
  if d =~? 'AccessDenied\|not authorized'
    return d . ' — this identity needs bedrock:InvokeModel on that model'
  endif
  if d =~? "don't have access to the model\\|access to the model with the specified"
    return d . ' — request model access in the Bedrock console for '
          \ . 'g:air_aws_region'
  endif
  if d =~? 'ValidationException'
    return d . ' — check g:air_model and g:air_aws_region (on-demand models '
          \ . 'often need the regional "us."/"eu." inference-profile prefix)'
  endif
  if d =~? 'ThrottlingException\|TooManyRequests'
    return d . ' — throttled by Bedrock; retry shortly'
  endif
  if d =~? 'Could not connect to the endpoint\|EndpointConnectionError'
    return d . ' — is g:air_aws_region a region where Bedrock is enabled?'
  endif
  return d
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
