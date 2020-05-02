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
* alternative patterns

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

# alternative patterns

When completion using `&iskeyword` does not produce any match, uses patterns in
`g:nearest_complete_lua_alt_patterns` to search for a more specific base from
previous base.

For example, if `reduce_pattern` is set to `[a-zA-Z0-9]`:

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

HelloWorld

HolaW
-----------
|HolaWorld|
-----------
```
