llhttp's own markdown test corpus, taken unmodified from the development
repository at tag v9.4.3 (archive sha256
d3897ec6263ba1eed13ecc37d54e9c42d6bb6f04c7852490bc8a7ef5326c53e1, MIT).
test/llhttp_corpus.sh replays every case through the beans_h1 bridge and
holds its trace to the upstream expectations, full-buffer and split at
every byte. url.md is not vendored: it exercises llparse's URL node, which
is below the llhttp C API this bridge wraps.
