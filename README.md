# vim-nearest-complete-lua
Vim plugin that sets completefunc to a nearest search function (in lua)

# usage

In vim using `<c-x><c-u>`.

Using SuperTab plugin with `let g:SuperTabDefaultCompletionType = "<c-x><c-u>"`

# features

* search lines starting from the nearest position from current cursor position
* respects `iskeyword` pattern
* respects `ignorecase`/`smartcase` settings
* handle completion in the middle of word
* also search all buffers in addition to current buffer
* expand search
* reduce search

# in-word completion

```
FileName
FileTime

f|e
-----------
| FileTim |
| FileNam |
-----------
```

# expand\_search

When completion using '&iskeyword' does not produce any match, retry using the
pattern from `expand_pattern`. This pattern creates a new search base if the
initial search base is empty.

# reduce\_search

When completion using '&iskeyword' does not produce any match, retry using the
pattern from `reduce_pattern`. This pattern is applied to the initial `base`.

For example, if `reduce_pattern' is set to '[a-zA-Z0-9]':

```
word1
word2

a_w|
---------
|a_word1|
|a_word2|
---------
```

```
enable_flag1
enable_flag2

disable_f|
---------------
|disable_flag1|
|disable_flag2|
---------------
```

When the cursor is positioned between `f` and `e`, the search matches
`FileName` and `FileTime` and the suffix `e` is removed from the
completions.
