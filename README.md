# vim-translate

Live Google Translate inside Vim. Put your source text on the left, get the
translation on the right — and export line-by-line pairs as a CSV for Anki.

```
:Translate      split the window in two and start translating
:Export         write the current buffer as an Anki-ready CSV
```

- Left window = your source text (editable, like the Google Translate input)
- Right window = the translation (read-only, updates while you type)
- `:translate` and `:export` (lowercase) also work.

---

## Requirements

- Vim 8+ or Neovim
- `curl`
- `json_decode()` is used when available (Vim ≥ 8.0.1450 / Neovim); there is a
  regex fallback otherwise.

## Installation

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'daniel-bergmann/vim-translate'
```

With [Vundle](https://github.com/VundleVim/Vundle.vim):

```vim
Plugin 'daniel-bergmann/vim-translate'
```

Manual:

```sh
git clone https://github.com/daniel-bergmann/vim-translate \
  ~/.vim/pack/plugins/start/vim-translate
```

## Configuration

All options live in `g:` variables and can be set before or after the plugin is
loaded. ISO 639-1 language codes throughout.

| Variable | Default | Meaning |
|---|---|---|
| `g:translate_source_lang` | `'auto'` | Source language (`'auto'` = detect) |
| `g:translate_target_lang` | `'en'` | Language shown on the right |
| `g:translate_debounce_ms` | `500` | Delay after typing stops before translating |
| `g:translate_export_file` | `'~/anki-import.csv'` | Where `:Export` writes the CSV |
| `g:translate_endpoint` | `https://translate.googleapis.com/translate_a/single` | Base URL of the translation API |
| `g:translate_client` | `'gtx'` | Value of the `client=` query parameter |
| `g:translate_fallback_endpoint` | `''` | Optional second endpoint to try if the first is blocked |
| `g:translate_fallback_client` | `'gtx'` | `client=` value for the fallback endpoint |
| `g:translate_user_agent` | Chrome UA string | `User-Agent` sent with every request |

Example (German → English, with a fallback host):

```vim
let g:translate_source_lang = 'de'
let g:translate_target_lang = 'en'

let g:translate_fallback_endpoint = 'https://clients5.google.com/translate_a/t'
let g:translate_fallback_client   = 'dict-chrome-ex'
```

## Usage

1. Open a file (or a new buffer) and type/paste your text.
2. Run `:Translate`. The window splits vertically:
   - left = your text
   - right = the translation, refreshed automatically as you edit the left.
3. Edit the left side; the right side updates after a short debounce.
4. When you are done, run `:Export`. Each non-empty line of the source file is
   translated and written as one CSV row:

   ```csv
   "Hallo, Welt","Hello, world"
   ```

   Run `:Export` from either window — it always uses the source text.

Quick demo: `vim examples/de-vocabulary.txt` and run `:Translate`.

## Importing into Anki

1. In Anki: **File → Import**.
2. Pick the CSV file (default `~/anki-import.csv`).
3. Choose your note type and map **field 1 → Front**, **field 2 → Back**.
4. Leave "Fields separated by: Comma". Import.

Tip: write one sentence/phrase per line in the source buffer — each line
becomes one card.

---

# How it works

## File layout

```
vim-translate/
├── plugin/translate.vim        loaded once at Vim startup
├── autoload/translate.vim      loaded lazily on first use
├── examples/de-vocabulary.txt  sample German vocabulary (one word per line)
├── LICENSE
└── README.md
```

- **`plugin/translate.vim`** is tiny on purpose: it registers the `:Translate`
  and `:Export` commands, the `:translate`/`:export` command-line
  abbreviations, the `g:` defaults, and one `autocmd` group. It never touches
  the network.
- **`autoload/translate.vim`** holds all the logic. Vim only loads it the first
  time a `translate#…` function is called, so the plugin costs nothing until
  you actually use it.

## The request

The plugin uses Google's *keyless* endpoint (no API key). For text `hello`,
source `auto`, target `en` it builds this URL:

```
https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q=hello
```

- `client=gtx` — the public, anonymous client id
- `sl=` / `tl=` — source / target language
- `dt=t` — request the translation data type
- `q=` — the text to translate (URL-encoded by curl's `--data-urlencode`)

The request is sent with `curl`:

```
curl -s --max-time 15 -A <browser-user-agent> \
     --get --data-urlencode q=<text> <base-url>
```

A real browser `User-Agent` is sent because Google rejects curl's default
`curl/x.y` agent with a "Sorry…" block page.

The response is JSON:

```json
[[["Hello","hello",null,null,10]],null,"en",…]
```

The translated text is the first string of each segment in `[0]` — segments are
joined together, so multi-sentence input works.

## Live update pipeline

```
you type in the left buffer
        │
        ▼
autocmd TextChanged / TextChangedI
        │  (only if the buffer has a b:translate_target)
        ▼
translate#schedule_update()          ── (re)starts a debounce timer per buffer
        │
        │  …you stop typing for g:translate_debounce_ms…
        ▼
translate#do_update()
        │
        ▼
translate#update()                   ── joins all buffer lines with \n
        │
        ▼
translate#translate_async()          ── starts an async curl job
        │
        ▼
job callbacks accumulate stdout
        │
        ▼
translate#on_translated()            ── applies the result to the right buffer
```

### Debounce

`translate#schedule_update()` keeps a timer per source buffer (in the
script-local `s:timers` dict). Every keystroke restarts that buffer's timer, so
the API is only hit after you pause for `g:translate_debounce_ms` milliseconds.

### Async jobs

- **Vim**: `job_start(['curl', …])` with an `out_cb` that appends chunks into
  `s:acc` (keyed by channel id) and a `close_cb` that fires the continuation
  once all output has arrived.
- **Neovim**: `jobstart(['curl', …])` with `on_stdout` accumulating into
  `s:nvim_acc` (keyed by job id) and `on_exit` firing the continuation.

Using a job instead of blocking `system()` means the editor never freezes while
the network round-trip is in flight.

### Stale-result protection

The response callback carries the exact text that was sent. Before writing to
the target buffer it re-reads the source and compares; if you've typed more in
the meantime, the result is discarded. This guarantees out-of-order responses
can never clobber a newer translation.

### Cancellation

Before starting a new job, any still-running job is stopped
(`job_stop()`/`jobstop()`), guarded by a `job_status() == 'run'` check (Vim) or
`jobwait(id, 0) == -1` (Neovim). Jobs already finished are left alone.

## The split

`:Translate` does this:

1. Creates a vertical split with a new scratch buffer on the right:
   `buftype=nofile bufhidden=hide noswapfile nobuflisted nomodifiable`.
2. Links the two buffers with buffer-local variables:

   | Variable | Set on | Holds |
   |---|---|---|
   | `b:translate_target` | source buffer | buffer number of the translation |
   | `b:translate_source` | target buffer | buffer number of the source |
   | `b:translate_is_target` | target buffer | flag (`1`) |

3. Runs an initial translation of the current contents.
4. Jumps back to the source window.

The target buffer is `nomodifiable`, so you can't accidentally type into it.
Programmatic writes temporarily flip `modifiable` on, use `setbufline()`, trim
any leftover lines with `deletebufline()`, then flip it back and clear the
`modified` flag.

Because the link is just buffer-local variables, re-running `:Translate` on a
buffer that already has a target simply re-focuses the existing split, and
running it *inside* the target buffer jumps back to the source.

## Blocked responses & fallback

The Google keyless endpoint sometimes returns an HTML "Sorry…" page (rate
limiting, flagged IP, missing agent). `translate#parse()` detects this by
checking for an empty body, `<html`, `Sorry`, or `CAPTCHA` and records it in
`s:last_error`.

`translate#endpoints()` builds an ordered list of `[endpoint, client]` pairs:
the primary, plus the fallback if `g:translate_fallback_endpoint` is set. Both
the async and sync paths walk that list, retrying the next endpoint whenever
the previous one reports a block.

```
primary endpoint ──blocked──▶ fallback endpoint ──ok──▶ translation
```

## Response parsing

`translate#parse()` handles three shapes:

1. **Nested** (standard `translate_a/single`):
   `[[["translated","orig",…]],null,"lang",…]` → joins `seg[0]` of each segment.
2. **Flat** (some mirror endpoints): `["translated","orig",…]` → returns `[0]`.
3. **Regex fallback** (Vim without `json_decode()`): grabs the first
   `[[["…","` segment with `matchstr()`.

## Export pipeline

`:Export` is intentionally *synchronous* — it's a one-shot action, so blocking
is fine and the code stays simple:

1. Resolves the source buffer (jumping across the split if you're on the right).
2. For each **non-empty** line, calls `translate#translate_sync()` (blocking
   `system(curl …)`, with the same endpoint-fallback loop).
3. Escapes both fields for CSV (`"` → `""`, and wraps in quotes if the field
   contains a comma, quote, or newline).
4. Writes `front,back` rows to `g:translate_export_file`.

Each line is translated individually so there is a guaranteed 1:1 mapping
between source lines and CSV rows — one line, one Anki card.

## Concurrency notes

- Only **one** async job is in flight at a time (the previous one is cancelled
  on a new request).
- Vim and Neovim accumulate output **per channel/job**, so even if two jobs
  overlapped they could not corrupt each other's output.
- The stale-result check is the final safety net for correctness.

---

## Notes & limitations

- The default endpoint is an *unofficial, keyless* Google endpoint. It is free
  and needs no API key, but it is not a public SLA: Google may rate-limit or
  block it. The fallback mechanism and the troubleshooting steps below cover
  the common cases; for heavy or guaranteed use, point `g:translate_endpoint`
  at a keyed/paid endpoint instead.
- The live view translates the **whole buffer as one request** (fast, but Google
  may merge/split sentences across lines). `:Export` translates **per line**, so
  lines map 1:1 to cards.

### If you see "Google Translate is blocked or unreachable"

1. **Wait a bit** — the block is often a temporary per-IP rate limit.
2. **Add a fallback endpoint** (see Configuration).
3. **Turn off your VPN** — datacenter/VPN IPs are the most common cause of a
   hard block.
4. **Switch providers** by changing `g:translate_endpoint` to a different
   compatible service.
# vim-translate
