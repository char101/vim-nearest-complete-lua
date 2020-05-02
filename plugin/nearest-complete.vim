if exists('g:loaded_nearest_complete_lua')
	finish
endif
let g:loaded_nearest_complete_lua = 1

" Alternative patterns that will be used against the search base. Useful for in-word completion.
" A pattern consists of a frontier pattern and a matching pattern. The frontier pattern is used to prevent in-word match.
let g:nearest_complete_lua_alt_patterns = [['%f[a-zA-Z0-9]', '[a-zA-Z0-9]+'], ['%f[A-Z]', '[A-Z]+[a-z0-9]*']]

" maximum number of results produced
let g:nearest_complete_lua_max_results = 20

let g:nearest_complete_lua_use_ignorecase = 0

le g:nearest_complete_lua_show_line_number = 0

exec 'luafile '.expand('<sfile>:p:h').'/complete.lua'

func! NearestComplete(findstart, base)
	if a:findstart
		return luaeval('find_start()')
	else
		return luaeval('find_completions()')
	endif
endf

set completefunc=NearestComplete
