-- use C module trim for 10x faster performance
if not pcall(require, 'trim') then
  function trim(s)
    local from = s:match"^%s*()"
    return from > #s and "" or s:match(".*%S", from)
  end
end

local PLUGIN = 'nearest_complete_lua'
local MAGIC_CHARS = '^$()%.[]*+-?'
local MAGIC_CHARS_PATTERN = '[' .. MAGIC_CHARS:gsub('.', function(m) return '%' .. m end) .. ']'
local MAGIC_CHARS_TABLE = {}
for _, b in pairs({string.byte(MAGIC_CHARS)}) do
  MAGIC_CHARS_TABLE[b] = true
end
local FALLBACK_PATTERN = '%S'

local g_iskeyword = nil
local g_ignorecase = nil
local g_pattern = nil

local opt_max_results = nil
local opt_alt_patterns = nil
local opt_show_line_number = nil

-- byte(number) to char, escaped when necessary
function byte_to_pattern(b)
  local c = string.char(b)
  if MAGIC_CHARS_TABLE[b] ~= nil then
    c = '%' .. c
  end
  return c
end

-- convert raw text to pattern
function text_to_pattern(s)
  local p = s:gsub(MAGIC_CHARS_PATTERN, function(m) return '%' .. m end)
  if g_ignorecase then
    p = s:gsub('[a-zA-Z]', function(m) return '[' .. m:lower() .. m:upper() .. ']' end)
  end
  return p
end

-- get ignorecase state
function get_ignorecase(base, suffix)
  if get_option('use_ignorecase') == 0 then
    return false
  end

  if vim.eval('&ignorecase') == 1 then
    if vim.eval('&smartcase') == 1 then
      if base ~= nil and base:match('[A-Z]') then
        return false
      end
      if suffix ~= nil and suffix:match('[A-Z]') then
        return false
      end
    end
    return true
  end
  return false
end

-- add lowercase or uppercase version to table of character bytes
function process_ignorecase_table(chars)
  local append = {}

  for b in pairs(chars) do
    if b >= 65 and b <= 90 then -- A-Z
      append[b + 32] = true
    end
    if b >= 97 and b <= 122 then -- a-z
      append[b - 32] = true
    end
  end

  for b in append do
    chars[b] = true
  end
end

-- convert from vim &iskeyword to characters map (in byte)
function get_keyword_pattern(iskeyword, ignorecase)
  local included = {}
  local excluded = {}

  -- handle special case of "^," to exclude ","
  if iskeyword:find('%^,[,$]') then
    excluded[44] = true -- ,
    iskeyword = iskeyword:gsub('%^,[,$]', '')
  end

  for k in iskeyword:gmatch('[^,]+') do
    if k == '@' then
      for a = 65, 90 do -- A-Z
        included[a] = true
      end
      for a = 97, 122 do -- a-z
        included[a] = true
      end
    elseif k == '-' then
      included[45] = true -- -
    elseif k == '@-@' then
      included[64] = true -- @
    elseif string.find(k, '-') then
      local first, last = k:match('([^-]+)-([^-]+)')
      local tab = included
      if first:sub(1, 1) == '^' then
        tab = excluded
        first = first:sub(2)
      end
      if not first:match('%d') then
        first = first:byte()
      end
      if not last:match('%d') then
        last = last:byte()
      end
      for a = first, last do
        tab[a] = true
      end
    else
      local tab = included
      if k ~= '^' and k:sub(1, 1) == '^' then
        tab = excluded
        k = k:sub(2)
      end
      if k:match('%d') then
        tab[tonumber(k)] = true
      else
        tab[k:byte()] = true
      end
    end
  end

  if ignorecase then
    process_ignorecase_table(included)
    process_ignorecase_table(excluded)
  end

  -- remove excluded characters
  local chars = {}
  local n = 1
  local has_dash = false
  for k in pairs(included) do
    if k == 45 then
      has_dash = true
    elseif not excluded[k] then
      chars[n] = k
      n = n + 1
    end
  end

  -- condense list of characters into pattern
  -- numeric keys on table are already sorted

  local pat = ''

  -- put dash if exists at the beginning
  if has_dash then
    pat = pat .. '-'
  end

  local prev = nil
  local is_dash = false
  local nchars = n - 1
  for i, k in ipairs(chars) do
    if prev == nil then
      pat = pat .. byte_to_pattern(k)
    elseif k == prev + 1 then
      if i == nchars then
        pat = pat .. '-' .. byte_to_pattern(k)
      else
        is_dash = true
      end
    else
      if is_dash then
        pat = pat .. '-' .. byte_to_pattern(prev)
        is_dash = false
      end
      pat = pat .. byte_to_pattern(k)
    end

    prev = k
  end

  return pat
end

-- find the start of completion target from current cursor position
function find_start()
  update_options()
  update_pattern()

  local col = vim.eval('col(".")') - 1
  local line = vim.line():sub(1, col)
  local found = line:find('[' .. g_pattern .. ']+$')
  -- print('\n')
  -- print(string.format('find_start: pos=[%s] str=[%s]', found, line:sub(found)))
  if found == nil then
    return ''
  end
  return tostring(found - 1)
end

-- find characters matching pattern after current cursor position
function find_suffix()
  local col = vim.eval('col(".")')
  local line = vim.line():sub(col)
  local suffix = line:match('^[' .. g_pattern .. ']+') -- suffix does not use fallback pattern
  if suffix == '' then
    suffix = nil
  end
  return suffix
end

function build_search_pattern(base, suffix, frontier)
  local pattern = g_pattern
  local search = (frontier == nil and ('%f[' .. pattern .. ']') or frontier) .. text_to_pattern(base) .. '[' .. pattern .. ']+'
  if suffix ~= nil then
    -- frontier pattern does not work here because we have reverse transition so this might match in-word
    search = search .. text_to_pattern(suffix)
  end
  -- print(string.format('update_search: base=[%s] suffix=[%s] search=[%s]', base, suffix, search))
  return search
end

function search_line(words, seen, text, search, reverse, info, prefix, suffix)
  local result = {}
  local max_result = opt_max_results - #words
  if info == nil then
    info = ''
  end

  -- pad with space so that the search below matches words that are at the beginning and end of the line
  text = ' ' .. text .. ' '

  local sidx = nil
  if suffix ~= nil then
    sidx = -#suffix - 1
  end

  -- print(string.format('search_line: text=[%s] search=[%s] prefix=[%s] suffix=[%s]', text, search, prefix, suffix))

  local n = 0
  local menu = info
  for word in text:gmatch(search) do
    if seen[word] == nil and n < max_result then
      n = n + 1
      seen[word] = true

      -- remove suffix from word
      if sidx ~= nil then
        word = word:sub(1, sidx)
        menu = (menu == '') and suffix or (suffix .. ' ' .. menu)
      end

      -- prepend prefix to word
      if prefix ~= nil then
        word = prefix .. word
      end

      -- print(string.format('search_line: (match) word=[%s] menu=[%s]', word, menu))
      result[n] = vim.dict({
        word = word,
        menu = menu
      })
    end
  end

  if n > 0 then
    local nw = #words
    if reverse then
      for i = #result, 1, -1 do
        nw = nw + 1
        words[nw] = result[i]
      end
    else
      for _, v in ipairs(result) do
        nw = nw + 1
        words[nw] = v
      end
    end
  end
end

function search_buffer(words, seen, buffer, line, col, search, base, prefix, suffix, file)
  local num_lines = #buffer
  local up = line
  local down = line
  local show_line_number = opt_show_line_number
  while up >= 1 or down <= num_lines do
    if up >= 1 then
      text = buffer[up]
      if up == line then
        text = text:sub(1, col - base:len())
      end
      if trim(text) ~= '' then
        -- print(string.format('search_buffer: (up) text=[%s] col=[%s] base=[%s]', text, col, base))
        local info = nil
        if file ~= nil then
          info = file .. ':' .. up
        elseif show_line_number then
          info = ':' .. (up - line)
        end
        search_line(words, seen, text, search, true, info, prefix, suffix)
        if #words >= opt_max_results then
          break
        end
      end
    end

    if down <= num_lines then
      text = buffer[down]
      if down == line then
        text = text:sub(col)
        if suffix ~= nil then
          text = text:sub(#suffix + 1)
        end
      end
      if trim(text) ~= '' then
        -- print(string.format('search_buffer: (down) text=[%s] col=[%s] base=[%s]', text, col, base))
        local info = nil
        if file ~= nil then
          info = file .. ':' .. down
        elseif show_line_number then
          info = ':' .. (down - line)
        end
        search_line(words, seen, text, search, false, info, prefix, suffix)
        if #words >= opt_max_results then
          break
        end
      end
    end

    up = up - 1
    down = down + 1
  end
end

function find_completions_for(words, seen, search, base, prefix, suffix)
  -- search current buffer
  local curbuf = vim.buffer()
  local curpos = vim.eval('getpos(".")')
  -- print(string.format('find_completions_for: search=[%s] base=[%s] prefix=[%s] suffix=[%s]', search, base, prefix, suffix))
  search_buffer(words, seen, curbuf, curpos[1], curpos[2], search, base, prefix, suffix)

  -- search other buffers
  if #words < opt_max_results then
    local buffers = {}
    local n = 1
    for buf in vim.eval('getbufinfo({"buflisted": 1, "bufloaded": 1})')() do
      local buftype = vim.eval('getbufvar(' .. buf.bufnr .. ', "&buftype")')
      if buftype == '' and buf.bufnr ~= curbuf.number then
        buffers[n] = buf
        n = n + 1
      end
    end

    table.sort(buffers, function (a, b) return a.lastused > b.lastused end)

    for _, buf in pairs(buffers) do
      -- buf.lnum is 0
      local file = vim.eval('fnamemodify(bufname(' .. buf.bufnr .. '), "%t")')
      if file == '' then
        file = '[No Name #' .. buf.bufnr .. ']'
      end
      search_buffer(words, seen, vim.buffer(buf.bufnr), buf.lnum == 0 and 1 or buf.lnum, 1, search, base, prefix, suffix, file)
      if #words >= opt_max_results then
        break
      end
    end
  end
end

function find_completions()
  local base = vim.eval('a:base')

  if base == '' then
    return vim.list()
  end

  local suffix = find_suffix()

  local words = {}
  local seen = {}

  if suffix ~= nil then
    if g_ignorecase then
      update_pattern(base, suffix)
    end

    -- search with base and suffix
    find_completions_for(words, seen, build_search_pattern(base, suffix), base, nil, suffix)
  end

  if #words < opt_max_results then
    -- search with base (ignoring suffix if exists)
    find_completions_for(words, seen, build_search_pattern(base), base)
  end

  if #words < opt_max_results then
    -- search using alternative patterns
    if #opt_alt_patterns > 0 then
      local alt_base = nil
      for fp in opt_alt_patterns() do
        local frontier = fp[0]
        local pattern = fp[1]
        alt_base = base:match(pattern .. '$')
        if alt_base ~= nil and alt_base ~= '' then
          local prefix = base:sub(1, #base - #alt_base)

          -- print(string.format('find_completions: (alt pattern) base=[%s] altbase=[%s] prefix=[%s] pat=[%s] frontier=[%s]', base, alt_base, prefix, pattern, frontier))

          if suffix ~= nil then
            -- search using alt pattern + suffix
            find_completions_for(words, seen, build_search_pattern(alt_base, suffix, frontier), base, prefix, suffix)
            if #words >= opt_max_results then
              break
            end
          end

          -- search using alt pattern only
          find_completions_for(words, seen, build_search_pattern(alt_base, nil, frontier), base, prefix)
          if #words >= opt_max_results then
            break
          end
        end
      end
    end
  end

  return vim.list(words)
end


function update_pattern(base, suffix)
  local iskeyword = vim.eval('&iskeyword')
  local ignorecase = get_ignorecase(base, suffix)
  if g_iskeyword ~= iskeyword or g_ignorecase ~= ignorecase then
    g_iskeyword = iskeyword
    g_ignorecase = ignorecase
    g_pattern = get_keyword_pattern(iskeyword)
  end
end

function update_options()
  opt_max_results = get_option('max_results')
  opt_alt_patterns = get_option('alt_patterns')
  opt_show_line_number = get_option('show_line_number')
end

function get_option(name)
  name = PLUGIN .. '_' .. name
  local value
  if vim.eval('exists("b:' .. name .. '")') == 1 then
    value = vim.eval('b:' .. name)
  elseif vim.eval('exists("g:' .. name .. '")') == 1 then
    value = vim.eval('g:' .. name)
  end
  if value == '' then
    value = nil
  end
  return value
end
