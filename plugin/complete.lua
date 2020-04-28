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

local g_max_results = nil
local g_expand_pattern = nil
local g_reduce_pattern = nil

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
  s = s:gsub(MAGIC_CHARS_PATTERN, function(m) return '%' .. m end)
  if g_ignorecase then
    s = s:gsub('[a-zA-Z]', function(m) return '[' .. m:lower() .. m:upper() .. ']' end)
  end
  return s
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
  if found == nil then
    if g_expand_pattern ~= nil then
      found = line:find('[' .. g_expand_pattern .. ']+$')
      if found == nil then
        return ''
      end
      g_pattern = g_expand_pattern
    end
    return ''
  end
  return tostring(found - 1)
end

-- find characters matching pattern after current cursor position
function find_suffix()
  local col = vim.eval('col(".")')
  local line = vim.line():sub(col)
  local suffix = line:match('^[' .. g_pattern .. ']+') -- suffix does not use fallback pattern
  return suffix
end

function search_line(words, seen, text, search, reverse, info, prefix, suffix)
  print('search_line', 'prefix', prefix)
  local result = {}
  local max_result = g_max_results - #words
  if info == nil then
    info = ''
  end

  local p = '%f[' .. (prefix == nil and g_pattern or g_reduce_pattern) .. ']' .. text_to_pattern(search) .. '[' .. g_pattern .. ']+'
  local sl = 0
  if suffix ~= nil then
    p = p .. text_to_pattern(suffix) .. '%f[^' .. g_pattern .. ']'
    sl = #suffix + 1
  end

  text = ' ' .. text .. ' ' -- lua frontier pattern does not work when the match is at the start or end of the line

  local n = 0
  local menu = info
  for word in text:gmatch(p) do
    if seen[word] == nil and n < max_result then
      n = n + 1
      seen[word] = true

      -- remove suffix from word
      if sl > 0 then
        word = word:sub(1, -sl)
        menu = suffix .. ' ' .. menu
      end

      -- prepend prefix to word
      if prefix ~= nil then
        word = prefix .. word
      end

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

-- words: table of found words
-- seen: table to check for previously found words
-- b: vim.buffer
-- line: starting line
-- col: starting col
-- base: search string
function search_buffer(words, seen, b, line, col, base, prefix, suffix, info)
  local num_lines = #b
  local up = line
  local down = line
  while up >= 1 or down <= num_lines do
    if up >= 1 then
      text = b[up]
      if up == line then
        text = text:sub(1, col - base:len())
      end
      if trim(text) ~= '' then
        search_line(words, seen, text, base, true, info == nil and ':' .. (up - line) or info .. ':' .. up, prefix, suffix)
        if #words >= g_max_results then
          break
        end
      end
    end

    if down <= num_lines then
      text = b[down]
      if down == line then
        text = text:sub(col + 1)
      end
      if trim(text) ~= '' then
        search_line(words, seen, text, base, false, info == nil and ':' .. (down - line) or info .. ':' .. down, prefix, suffix)
        if #words >= g_max_results then
          break
        end
      end
    end

    up = up - 1
    down = down + 1
  end
end

function find_completions_for(base, prefix)
  if base == '' then
    return {}
  end

  local suffix = find_suffix()
  update_pattern(base, suffix)

  local words = {}
  local seen = {}

  -- search current buffer
  local curbuf = vim.buffer()
  local curpos = vim.eval('getpos(".")')
  search_buffer(words, seen, curbuf, curpos[1], curpos[2], base, prefix, suffix)

  -- search other buffers
  if #words < g_max_results then
    local buffers = {}
    for buf in vim.eval('getbufinfo({"buflisted": 1, "bufloaded": 1})')() do
      if buf.hidden == 0 and buf.bufnr ~= curbuf.number then
        table.insert(buffers, buf)
      end
    end
    table.sort(buffers, function (a, b) return a.lastused > b.lastused end)
    for _, buf in pairs(buffers) do
      -- buf.lnum is 0
      local name = vim.eval('fnamemodify(bufname(' .. buf.bufnr .. '), "%t")')
      search_buffer(words, seen, vim.buffer(buf.bufnr), buf.lnum == 0 and 1 or buf.lnum, 1, base, prefix, suffix, name)
      if #words >= g_max_results then
        break
      end
    end
  end
  return words
end

function find_completions()
  local base = vim.eval('a:base')

  if base == '' then
    return vim.list()
  end

  local words = find_completions_for(base)
  if #words == 0 then
    -- reduce base
    if g_reduce_pattern ~= nil then
      local rbase = base:match('[' .. g_reduce_pattern .. ']+$')
      if rbase ~= nil and rbase ~= '' and rbase ~= base then
        local prefix = base:sub(1, #base - #rbase)
        print('prefix', prefix)
        words = find_completions_for(rbase, prefix)
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
  g_max_results = get_option('max_results')
  g_expand_pattern = get_option('expand_pattern')
  g_reduce_pattern = get_option('reduce_pattern')
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
