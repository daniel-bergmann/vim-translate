" vim-translate — live Google Translate split + Anki CSV export
" See README.md for setup and configuration.

if exists('g:loaded_vim_translate')
  finish
endif
let g:loaded_vim_translate = 1

" Defaults (override these in your vimrc):
"   let g:translate_source_lang = 'auto'   " source language (or 'en', 'de', ...)
"   let g:translate_target_lang = 'en'     " target language
"   let g:translate_debounce_ms  = 500     " delay after typing before translating
"   let g:translate_endpoint     = 'https://translate.googleapis.com/translate_a/single'
"   let g:translate_export_file  = '~/anki-import.csv'
let g:translate_source_lang = get(g:, 'translate_source_lang', 'auto')
let g:translate_target_lang = get(g:, 'translate_target_lang', 'en')
let g:translate_debounce_ms  = get(g:, 'translate_debounce_ms', 500)
let g:translate_endpoint     = get(g:, 'translate_endpoint', 'https://translate.googleapis.com/translate_a/single')
let g:translate_export_file  = get(g:, 'translate_export_file', '~/anki-import.csv')
let g:translate_user_agent   = get(g:, 'translate_user_agent', 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
let g:translate_client       = get(g:, 'translate_client', 'gtx')
let g:translate_fallback_endpoint = get(g:, 'translate_fallback_endpoint', '')
let g:translate_fallback_client   = get(g:, 'translate_fallback_client', 'gtx')

" Commands ------------------------------------------------------------------
command! -nargs=0 Translate call translate#open()
command! -nargs=0 Export    call translate#export()

" Allow typing the lowercase versions too (:translate, :export).
cnoreabbrev <expr> translate getcmdtype() ==# ':' && getcmdline() ==# 'translate' ? 'Translate' : 'translate'
cnoreabbrev <expr> export    getcmdtype() ==# ':' && getcmdline() ==# 'export'    ? 'Export'    : 'export'

" Re-translate on every change in any source buffer that has a target buffer.
augroup vim_translate
  autocmd!
  autocmd TextChanged,TextChangedI *
        \ if exists('b:translate_target') && b:translate_target
        \ |   call translate#schedule_update()
        \ | endif
augroup END
