" vim-translate — autoload functions
" Live Google Translate in a vertical split, with CSV export for Anki.

" State ---------------------------------------------------------------------

let s:job = -1            " in-flight curl job (vim or nvim handle)
let s:acc = {}            " stdout accumulator for vim jobs (keyed by channel id)
let s:nvim_acc = {}       " stdout accumulator for nvim jobs (keyed by job id)
let s:timers = {}         " debounce timers, keyed by source buffer
let s:last_error = 0      " set by translate#parse() when the API is blocked

" Configuration helpers -----------------------------------------------------

function! translate#source() abort
  return get(g:, 'translate_source_lang', 'auto')
endfunction

function! translate#target() abort
  return get(g:, 'translate_target_lang', 'en')
endfunction

function! translate#debounce() abort
  return get(g:, 'translate_debounce_ms', 500)
endfunction

function! translate#endpoint() abort
  return get(g:, 'translate_endpoint', 'https://translate.googleapis.com/translate_a/single')
endfunction

function! translate#user_agent() abort
  return get(g:, 'translate_user_agent',
        \ 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36')
endfunction

function! translate#client() abort
  return get(g:, 'translate_client', 'gtx')
endfunction

function! translate#fallback_endpoint() abort
  return get(g:, 'translate_fallback_endpoint', '')
endfunction

function! translate#fallback_client() abort
  return get(g:, 'translate_fallback_client', 'gtx')
endfunction

" Ordered list of [endpoint, client] pairs to try, in order.
function! translate#endpoints() abort
  let eps = [[translate#endpoint(), translate#client()]]
  let fb = translate#fallback_endpoint()
  if fb !=# ''
    call add(eps, [fb, translate#fallback_client()])
  endif
  return eps
endfunction

" Public commands -----------------------------------------------------------

" Open (or focus) the translation split.
function! translate#open() abort
  " If we are in a translation buffer, jump back to its source buffer.
  if get(b:, 'translate_is_target', 0)
    let src = get(b:, 'translate_source', 0)
    if src > 0 && bufexists(src)
      execute 'buffer' src
      return
    endif
  endif

  " If this buffer already has a target buffer, show it again.
  let tgt = get(b:, 'translate_target', 0)
  if tgt > 0 && bufexists(tgt)
    execute 'vertical rightbelow sbuffer' tgt
    return
  endif

  let source_buf = bufnr('%')

  " Create the (read-only) translation buffer on the right.
  vertical rightbelow new
  let target_buf = bufnr('%')
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted nomodifiable
  execute 'file [translate-' . translate#target() . ']'

  " Link the two buffers together.
  call setbufvar(source_buf, 'translate_target', target_buf)
  call setbufvar(target_buf, 'translate_is_target', 1)
  call setbufvar(target_buf, 'translate_source', source_buf)

  " Translate the current contents right away.
  call translate#update(source_buf, target_buf)

  " Jump back to the source (left) window.
  wincmd p
endfunction

" Export the source buffer to a CSV file suitable for Anki.
function! translate#export() abort
  if !executable('curl')
    call translate#warn('curl not found — cannot translate')
    return
  endif

  let src = translate#export_source_buffer()
  let lines = getbufline(src, 1, '$')
  let rows = []
  let card_count = 0

  for line in lines
    if line =~# '^\s*$'
      continue
    endif
    let trans = translate#translate_sync(line)
    if trans ==# ''
      call translate#warn('skipped a line (empty/blocked response)')
      continue
    endif
    call add(rows, translate#csv_escape(line) . ',' . translate#csv_escape(trans))
    let card_count += 1
  endfor

  if card_count == 0
    call translate#warn('nothing to export')
    return
  endif

  let path = expand(get(g:, 'translate_export_file', '~/anki-import.csv'))
  call writefile(rows, path)
  echom '[translate] Exported ' . card_count . ' card(s) to ' . path
endfunction

" Debounced live update -----------------------------------------------------

" Called from the TextChanged/TextChangedI autocmd.
function! translate#schedule_update() abort
  let buf = bufnr('%')
  if has_key(s:timers, buf)
    call timer_stop(s:timers[buf])
  endif
  let s:timers[buf] = timer_start(translate#debounce(), function('translate#do_update', [buf]))
endfunction

function! translate#do_update(source_buf, timer) abort
  if has_key(s:timers, a:source_buf)
    call remove(s:timers, a:source_buf)
  endif
  if !bufexists(a:source_buf)
    return
  endif
  let tgt = getbufvar(a:source_buf, 'translate_target')
  if tgt > 0 && bufexists(tgt)
    call translate#update(a:source_buf, tgt)
  endif
endfunction

" Translate the whole source buffer and write it into the target buffer.
function! translate#update(source_buf, target_buf) abort
  let text = join(getbufline(a:source_buf, 1, '$'), "\n")
  if text =~# '^\s*$'
    call translate#set_buffer_lines(a:target_buf, [''])
    return
  endif
  call translate#translate_async(text, function('translate#on_translated', [a:target_buf, text]))
endfunction

" Async callback: apply the result unless the source changed meanwhile.
function! translate#on_translated(target_buf, source_text, json) abort
  let src = getbufvar(a:target_buf, 'translate_source')
  if src > 0 && bufexists(src)
    let current = join(getbufline(src, 1, '$'), "\n")
    if current !=# a:source_text
      return  " stale result — a newer edit is pending
    endif
  endif

  let translated = translate#parse(a:json)
  if translated ==# '' && s:last_error
    call translate#warn('Google Translate is blocked or unreachable')
    return
  endif
  call translate#set_buffer_lines(a:target_buf, split(translated, "\n", 1))
endfunction

" HTTP ----------------------------------------------------------------------

" Kick off an asynchronous curl job. a:callback receives the raw JSON string.
function! translate#translate_async(text, callback) abort
  if !executable('curl')
    call translate#warn('curl not found — cannot translate')
    return
  endif
  call translate#cancel_job()
  call s:translate_async_endpoints(a:text, a:callback, translate#endpoints())
endfunction

function! s:translate_url(endpoint, client, text) abort
  return a:endpoint . '?client=' . a:client
        \ . '&sl=' . translate#source()
        \ . '&tl=' . translate#target()
        \ . '&dt=t'
endfunction

function! s:translate_async_endpoints(text, callback, endpoints) abort
  if empty(a:endpoints)
    call translate#warn('Google Translate is blocked or unreachable')
    return
  endif

  let [endpoint, client] = a:endpoints[0]
  let rest = a:endpoints[1:]
  let base = s:translate_url(endpoint, client, a:text)
  let cmd = ['curl', '-s', '--max-time', '15', '-A', translate#user_agent(),
        \ '--get', '--data-urlencode', 'q=' . a:text, base]

  " On a blocked response, retry with the next endpoint in the list.
  let Cb = function('s:on_async_result', [a:text, a:callback, rest])

  if has('nvim')
    let s:job = jobstart(cmd, {
          \ 'on_stdout': function('s:nvim_stdout', [Cb]),
          \ 'on_exit':    function('s:nvim_exit', [Cb]),
          \ })
  else
    let s:job = job_start(cmd, {
          \ 'out_cb':   function('s:vim_out'),
          \ 'close_cb': function('s:vim_close', [Cb]),
          \ 'err_cb':   function('s:vim_err'),
          \ })
  endif
endfunction

function! s:on_async_result(text, callback, rest, json) abort
  let translated = translate#parse(a:json)
  if translated ==# '' && s:last_error && !empty(a:rest)
    call s:translate_async_endpoints(a:text, a:callback, a:rest)
    return
  endif
  call a:callback(a:json)
endfunction

function! translate#cancel_job() abort
  " In Vim a job is a Job object (v:t_job); in Neovim it is a numeric id.
  if has('nvim')
    if s:job == -1
      return
    endif
  else
    if type(s:job) != v:t_job
      return
    endif
  endif
  try
    if has('nvim')
      " jobwait(id, 0) returns -1 while the job is still running
      if jobwait([s:job], 0)[0] == -1
        call jobstop(s:job)
      endif
    else
      if job_status(s:job) ==# 'run'
        call job_stop(s:job)
      endif
    endif
  catch
    " ignore — the job may have finished already
  endtry
  let s:job = -1
endfunction

" Vim job callbacks ---------------------------------------------------------

function! s:vim_out(channel, msg) abort
  let id = ch_info(a:channel).id
  let s:acc[id] = get(s:acc, id, '') . a:msg
endfunction

function! s:vim_err(channel, msg) abort
  " ignore stderr (curl progress/errors)
endfunction

function! s:vim_close(callback, channel) abort
  let id = ch_info(a:channel).id
  let result = get(s:acc, id, '')
  if has_key(s:acc, id)
    call remove(s:acc, id)
  endif
  call a:callback(result)
endfunction

" Neovim job callbacks ------------------------------------------------------

function! s:nvim_stdout(callback, jobid, data, event) abort
  let s:nvim_acc[a:jobid] = get(s:nvim_acc, a:jobid, '') . join(a:data, "\n")
endfunction

function! s:nvim_exit(callback, jobid, code, event) abort
  let result = get(s:nvim_acc, a:jobid, '')
  if has_key(s:nvim_acc, a:jobid)
    call remove(s:nvim_acc, a:jobid)
  endif
  call a:callback(result)
endfunction

" Synchronous translation (used by :Export) ---------------------------------

function! translate#translate_sync(text) abort
  for [endpoint, client] in translate#endpoints()
    let base = s:translate_url(endpoint, client, a:text)
    let cmd = 'curl -s --max-time 15 -A ' . shellescape(translate#user_agent())
          \ . ' --get --data-urlencode '
          \ . shellescape('q=' . a:text) . ' ' . shellescape(base)
    let json = system(cmd)
    let translated = translate#parse(json)
    if translated !=# '' || !s:last_error
      return translated
    endif
  endfor
  return ''
endfunction

" Parsing -------------------------------------------------------------------

" Extract translated text from the Google Translate JSON response.
function! translate#parse(json) abort
  let s:last_error = 0
  let raw = a:json

  if raw ==# '' || raw =~# '<html\|Sorry\|CAPTCHA'
    let s:last_error = 1
    return ''
  endif

  if exists('*json_decode')
    try
      let resp = json_decode(raw)
      if type(resp) == v:t_list && len(resp) > 0
        if type(resp[0]) == v:t_list
          " [[["translated","orig",...]],null,"lang",...]
          let parts = []
          for seg in resp[0]
            if type(seg) == v:t_list && len(seg) > 0 && type(seg[0]) == v:t_string
              call add(parts, seg[0])
            endif
          endfor
          return join(parts, '')
        elseif type(resp[0]) == v:t_string
          " ["translated","orig",...]
          return resp[0]
        endif
      endif
    catch
      " fall through to regex below
    endtry
  endif

  " Fallback for Vim without json_decode(): grab the first segment.
  return matchstr(raw, '\[\[\["\zs.\{-}\ze","')
endfunction

" Buffer helpers ------------------------------------------------------------

" Replace the contents of buffer a:buf with a:lines (list of strings).
" Works even while the buffer is 'nomodifiable'.
function! translate#set_buffer_lines(buf, lines) abort
  if !bufexists(a:buf)
    return
  endif
  call setbufvar(a:buf, '&modifiable', 1)
  try
    let lines = empty(a:lines) ? [''] : a:lines
    let old = len(getbufline(a:buf, 1, '$'))
    call setbufline(a:buf, 1, lines)
    if old > len(lines)
      call deletebufline(a:buf, len(lines) + 1, old)
    endif
  finally
    call setbufvar(a:buf, '&modifiable', 0)
    call setbufvar(a:buf, '&modified', 0)
  endtry
endfunction

function! translate#export_source_buffer() abort
  if get(b:, 'translate_is_target', 0)
    return get(b:, 'translate_source', bufnr('%'))
  endif
  return bufnr('%')
endfunction

function! translate#csv_escape(s) abort
  let s = a:s
  if s =~# '[",\n]'
    let s = substitute(s, '"', '""', 'g')
    let s = '"' . s . '"'
  endif
  return s
endfunction

function! translate#warn(msg) abort
  echohl WarningMsg
  echom '[translate] ' . a:msg
  echohl None
endfunction
