# 7-Zip engine

Kkuk includes the standalone 7zz command-line program, version 26.03.
Copyright (C) 1999–2026 Igor Pavlov. https://7-zip.org/

The binary is copied from the user's local 7-Zip installation at build time,
then signed locally for the app bundle. Engine source code is not modified.

- Corresponding source archive: https://7-zip.org/a/7z2603-src.7z
- Source repository: https://github.com/ip7z/7zip/tree/26.03
- License notices: 7zip-LICENSE.txt
- GNU LGPL 2.1 text: 7zip-COPYING.txt

Builds require version 26.03. The engine executable is excluded from Git; a
replacement can be supplied through `KKUK_7ZZ_PATH` when rebuilding. The app
runs the bundled engine without a Homebrew dependency at runtime.
