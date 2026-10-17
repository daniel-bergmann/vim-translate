# translate.vim

Translate text with Google Translate, live, right inside Vim.  Put your
source on the left, read the translation on the right — it updates as you
type.  When you're done, export the lot as a CSV for Anki.

That's about it.

## Installation

Install using your favorite package manager, or use Vim's built-in package
support:

    mkdir -p ~/.vim/pack/daniel/start
    cd ~/.vim/pack/daniel/start
    git clone https://github.com/daniel-bergmann/vim-translate.git

With vim-plug:

    Plug 'daniel-bergmann/vim-translate'

## Usage

Run `:Translate` to open a split with your text on the left and a read-only
translation on the right.  Edit the left side and the right side keeps up.
Run `:Export` to write every non-empty line to a CSV as `source,translation`,
ready to import into Anki.

Want to see it in action?  `vim examples/de-vocabulary.txt` and run
`:Translate`.

## Configuration

Set these in your vimrc:

    let g:translate_source_lang = 'de'   " source language ('auto' to detect)
    let g:translate_target_lang = 'en'   " language shown on the right
    let g:translate_debounce_ms  = 500   " pause before re-translating
    let g:translate_export_file  = '~/anki-import.csv'

If Google blocks the default endpoint (it happens), add a fallback:

    let g:translate_fallback_endpoint = 'https://clients5.google.com/translate_a/t'
    let g:translate_fallback_client   = 'dict-chrome-ex'

## FAQ

> It says "Google Translate is blocked or unreachable."

The keyless endpoint gets rate-limited and frowns on VPNs.  Wait a bit, add
the fallback above, or point `g:translate_endpoint` at a keyed provider.

## Contributing

See the contribution guidelines for
[pathogen.vim](https://github.com/tpope/vim-pathogen#readme).

## License

Copyright (c) 2026 Daniel Bergmann.  Distributed under the MIT License.
See [LICENSE](LICENSE).
