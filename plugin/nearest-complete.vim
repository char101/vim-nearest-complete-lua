exec 'luafile '.expand('<sfile>:p:h').'/complete.lua'

func! NearestComplete(findstart, base)
	if a:findstart
		return luaeval('find_start()')
	else
		return luaeval('find_completions()')
	endif
endf

set completefunc=NearestComplete
