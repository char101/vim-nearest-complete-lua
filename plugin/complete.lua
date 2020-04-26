local MAGIC_CHARS = '^$()%.[]*+-?'
local MAGIC_CHARS_PATTERN = '[' .. MAGIC_CHARS:gsub('.', function(m) return '%' .. m end) .. ']'
local MAGIC_CHARS_TABLE = {}
for _, b in pairs({string.byte(MAGIC_CHARS)}) do
  MAGIC_CHARS_TABLE[b] = true;
end

local MAX_RESULT = 20

local g_iskeyword = nil
local g_ignorecase = nil
local g_pattern = nil

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
    excluded[string.byte(',')] = true
    iskeyword = iskeyword:gsub('%^,[,$]', '')
  end

  for k in iskeyword:gmatch('[^,]+') do
    if k == '@' then
      for a = string.byte('a'), string.byte('z') do
        included[a] = true
      end
      for a = string.byte('A'), string.byte('Z') do
        included[a] = true
      end
    elseif k == '-' then
      included[string.byte('-')] = true
    elseif k == '@-@' then
      included[string.byte('@')] = true
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
    if k == string.byte('-') then
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
  update_pattern()
  local col = vim.eval('col(".")') - 1
  local line = vim.line():sub(1, col)
  local start = line:find('[' .. g_pattern .. ']+$') - 1
  return tostring(start)
end

-- find characters matching pattern after current cursor position
function find_suffix()
  local col = vim.eval('col(".")')
  local line = vim.line():sub(col)
  local suffix = line:match('^[' .. g_pattern .. ']+')
  if suffix == nil then
    suffix = ''
  end
  return suffix
end

function search_line(words, seen, text, search, suffix, reverse, info)
  local result = {}
  local max_result = MAX_RESULT - #words
  if info == nil then
    info = ''
  end

  local p = '%f[' .. g_pattern .. ']' .. text_to_pattern(search) .. '[' .. g_pattern .. ']+'
  local sl = 0
  if suffix ~= nil and suffix ~= '' then
    p = p .. text_to_pattern(suffix) .. '%f[^' .. g_pattern .. ']'
    sl = #suffix + 1
  end

  local n = 0
  local menu = info
  for word in text:gmatch(p) do
    if seen[word] == nil then
      n = n + 1
      seen[word] = true
      if sl > 0 then
        word = word:sub(1, -sl)
        menu = suffix .. ' ' .. menu
      end

      result[n] = vim.dict({
        word = word,
        menu = menu
      })
      if n == max_result then
        break
      end
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
function search_buffer(words, seen, b, line, col, base, suffix, info)
  print('sb', #b, line, info)
  local num_lines = #b
  local up = line
  local down = line
  info = info or ''
  while up >= 1 or down <= num_lines do
    if up >= 1 then
      text = b[up]
      if up == line then
        text = text:sub(1, col - base:len())
      end
      search_line(words, seen, text, base, suffix, true, (info == nil or info == '') and ':' .. (up - line) or info .. ':' .. up)
      if #words >= MAX_RESULT then
        break
      end
    end

    if down <= num_lines then
      text = b[down]
      if down == line then
        text = text:sub(col + 1)
      end
      search_line(words, seen, text, base, suffix, false, (info == nil or info == '') and ':' .. (down - line) or info .. ':' .. down)
      if #words >= MAX_RESULT then
        break
      end
    end

    up = up - 1
    down = down + 1
  end
end

function find_completions()
  local base = vim.eval('a:base')
  if base ~= '' then
    local suffix = find_suffix()
    update_pattern(base, suffix)

    local words = {}
    local seen = {}

    -- search current buffer
    local curbuf = vim.buffer()
    local curpos = vim.eval('getpos(".")')
    search_buffer(words, seen, curbuf, curpos[1], curpos[2], base, suffix)

    -- search other buffers
    if #words < MAX_RESULT then
      local buffers = {}
      for buf in vim.eval('getbufinfo({"buflisted": 1, "bufloaded": 1})')() do
        print('b1', buf.name, buf.hidden)
        if buf.hidden == 0 and buf.bufnr ~= curbuf.number then
          table.insert(buffers, buf)
        end
      end
      table.sort(buffers, function (a, b) return a.lastused > b.lastused end)
      for _, buf in pairs(buffers) do
        -- buf.lnum is 0
        local name = vim.eval('fnamemodify(bufname(' .. buf.bufnr .. '), "%t")')
        search_buffer(words, seen, vim.buffer(buf.bufnr), buf.lnum == 0 and 1 or buf.lnum, 1, base, suffix, name)
        if #words >= MAX_RESULT then
          break
        end
      end
    end
    return vim.list(words)
  else
    return vim.list()
  end
end

function update_pattern(base, suffix)
  local k = vim.eval('&iskeyword')
  local ignorecase = get_ignorecase(base, suffix)
  if g_iskeyword ~= k or g_ignorecase ~= ignorecase then
    g_iskeyword = k
    g_ignorecase = ignorecase
    g_pattern = get_keyword_pattern(k)
    print('update_pattern', base, suffix, ignorecase, g_pattern)
  end
end
