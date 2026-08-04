" Syntax for the air prompt buffer

if exists('b:current_syntax')
  finish
endif

syntax match airComment  /^#.*/ contains=airDirective
syntax match airDirective /^#\s*scope:\s*\S\+/ contained

highlight default link airComment   Comment
highlight default link airDirective Identifier

let b:current_syntax = 'air'
