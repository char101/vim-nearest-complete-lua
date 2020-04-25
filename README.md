# vim-nearest-complete-lua
Vim plugin that sets completefunc to a nearest search function (in lua)

# usage

In vim using `<c-x><c-u>`.

Using SuperTab plugin with `let g:SuperTabDefaultCompletionType = "<c-x><c-u>"`

# features

* search from the nearest line from current cursor position
* respects `iskeyword` pattern
* respects `ignorecase`/`smartcase` settings
* handle completion in the middle of word
* also search all buffers in addition to current buffer

# in-word completion

```
FileName
FileTime

f|e
| FileTim |
| FileNam |
```

When the cursor is positioned between `f` and `e`, the completions are matched
against `FileName` and `FileTime` and the suffix `e` is removed from the
completions.
