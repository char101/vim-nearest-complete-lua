if exists('g:loaded_nearest_complete_lua')
	finish
endif
let g:loaded_nearest_complete_lua = 1

" pattern to use when the search using &iskeyword does not product any matches
" if find_start does not get a match, then it will use this pattern
" the pattern should only consists of characters that will fit inside '[]'
" let g:nearest_complete_lua_expand_pattern = '%S'

" pattern to use when the search using &iskeyword does not produce any matches
" if find_completions does not find a match, then it will use this pattern to reduce the base string and retry
" the pattern should only consists of characters that will fit inside '[]'
let g:nearest_complete_lua_reduce_pattern = 'a-zA-Z0-9'

" maximum number of results produced
let g:nearest_complete_lua_max_results = 20

exec 'luafile '.expand('<sfile>:p:h').'/complete.lua'

func! NearestComplete(findstart, base)
	if a:findstart
		return luaeval('find_start()')
	else
		return luaeval('find_completions()')
	endif
endf

set completefunc=NearestComplete
