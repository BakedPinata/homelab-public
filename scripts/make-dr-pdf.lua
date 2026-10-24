-- Pandoc filter for scripts/make-dr-pdf.sh (R23): fills docs/disaster-recovery.template.md.
-- Runs inside the pandoc container with the repo mounted read-only at /repo.
-- {{dr.KEY}} reads dr.env, {{<service>.KEY}} services/<service>/.env, {{gen.KEY}} the script's
-- DR_* variables; <domain> becomes the real domain. DR_SAMPLE=1 reads the .env.sample files instead.
-- Values go in as text, never parsed as markdown, so a secret can't change the layout.
local REPO = '/repo'
local SUFFIX = os.getenv('DR_SAMPLE') == '1' and '.env.sample' or '.env'
local NOT_SET = '(not set)'

-- KEY=value lines as Docker Compose reads them: quotes stripped, " #" starts a comment if unquoted
local function read_env(path)
  local f = io.open(path)
  if not f then return nil end
  local env = { vals = {}, keys = {} }
  for line in f:lines() do
    local k, v = line:match('^%s*([%a_][%w_]*)=(.*)$')
    if k then
      local q = v:sub(1, 1)
      if q == '"' or q == "'" then
        v = v:sub(2, (v:find(q, 2, true) or 0) - 1)
      else
        v = v:gsub('%s+#.*$', ''):gsub('%s+$', '')
      end
      if not env.vals[k] then table.insert(env.keys, k) end
      env.vals[k] = v
    end
  end
  f:close()
  return env
end

local sources, services = {}, {}
sources.dr = read_env(REPO .. '/dr' .. SUFFIX) or error('dr' .. SUFFIX .. ' not found')
local names = pandoc.system.list_directory(REPO .. '/services')
table.sort(names)
for _, s in ipairs(names) do
  local env = read_env(REPO .. '/services/' .. s .. '/' .. SUFFIX)
  if env then sources[s] = env; table.insert(services, s) end
end
local DOMAIN = (sources.traefik or error('services/traefik/' .. SUFFIX .. ' not found')).vals.DOMAIN
sources.gen = { vals = { DATE = os.getenv('DR_DATE'), COMMIT = os.getenv('DR_COMMIT'), DOMAIN = DOMAIN } }

local missing = {}
local function lookup(ref)
  local src, key = ref:match('^([%w_-]+)%.([%w_]+)$')
  local v = src and sources[src] and sources[src].vals[key]
  if v == nil then missing[ref] = true; return '{{' .. ref .. '}}' end
  return v == '' and NOT_SET or v
end
local function fill(s)
  s = s:gsub('{{([%w_.-]+)}}', lookup)
  return (s:gsub('<domain>', function() return DOMAIN end))
end

-- Monospace, with break points every 16 characters so long tokens wrap inside table cells
local function code(s)
  local out, i = pandoc.Inlines {}, 1
  while i <= #s do
    local j = utf8.offset(s, 17, i) or #s + 1
    if i > 1 then out:insert(pandoc.RawInline('latex', '\\allowbreak{}')) end
    out:insert(pandoc.Code(s:sub(i, j - 1)))
    i = j
  end
  return out
end
-- Break points after . / @ _ - : = , so addresses, paths and key names wrap in narrow cells.
-- force also breaks a run of 16 characters without one (code, never prose words).
local function breakable(s, mk, force)
  local out, buf, run = pandoc.Inlines {}, '', 0
  local function flush()
    if buf == '' then return end
    if #out > 0 then out:insert(pandoc.RawInline('latex', '\\penalty100{}')) end -- a space is a better break
    out:insert(mk(buf)); buf = ''; run = 0
  end
  for _, c in utf8.codes(s) do
    local ch = utf8.char(c)
    buf = buf .. ch
    run = ch == ' ' and 0 or run + 1
    if ch:match('[%./@_:=,%-]') or (force and run >= 16) then flush() end
  end
  flush()
  return out
end
local function text(s)
  return pandoc.Inlines(s):walk { Str = function(el) return breakable(el.text, pandoc.Str) end }
end

-- Inline placeholders. Adjacent Str elements are merged first so no placeholder is split.
local fill_filter = {
  Inlines = function(inlines)
    local out = pandoc.Inlines {}
    for _, el in ipairs(inlines) do
      if el.t == 'RawInline' and el.format == 'html' and el.text:match('^<[%w-]+>$') then
        el = pandoc.Str(el.text) -- <name>-style placeholders in the docs, not HTML
      end
      local last = out[#out]
      if el.t == 'Str' and last and last.t == 'Str' then
        last.text = last.text .. el.text
      else
        out:insert(el)
      end
    end
    local filled = pandoc.Inlines {}
    for _, el in ipairs(out) do
      local ref = el.t == 'Code' and el.text:match('^{{([%w_.-]+)}}$')
      if ref then
        filled:extend(code(lookup(ref)))
      elseif el.t == 'Code' then
        filled:extend(breakable(fill(el.text), pandoc.Code, true))
      elseif el.t == 'Str' then
        filled:extend(breakable(fill(el.text), pandoc.Str))
      else
        filled:insert(el)
      end
    end
    return filled
  end,
  CodeBlock = function(el) el.text = fill(el.text); return el end,
}

local function table_of(headers, widths, rows)
  local function cell(inlines) return { pandoc.Plain(inlines) } end
  local head, body, aligns = {}, {}, {}
  for i, h in ipairs(headers) do head[i] = cell(pandoc.Inlines(h)); aligns[i] = pandoc.AlignDefault end
  for i, row in ipairs(rows) do
    body[i] = {}
    for j, c in ipairs(row) do body[i][j] = cell(c) end
  end
  return pandoc.utils.from_simple_table(pandoc.SimpleTable({}, aligns, widths, head, body))
end

local function secrets(env)
  local rows = {}
  for _, k in ipairs(env.keys) do
    if not k:match('^ACCOUNT_%d+$') then
      local v = env.vals[k]
      table.insert(rows, { breakable(k, pandoc.Code, true), v == '' and pandoc.Inlines { pandoc.Emph(NOT_SET) } or code(v) })
    end
  end
  return table_of({ 'Key', 'Value' }, { 0.4, 0.6 }, rows)
end

-- A table too wide for the page gets column widths, so its cells wrap. Widths are in rough
-- character widths of 11pt DejaVu (code is a bit wider). Each column gets at least its longest
-- word; the space left goes to the columns with the most text. page is the text width in pt.
local PORTRAIT, LANDSCAPE = 482, 728
local function widen(t, page)
  local n = #t.colspecs
  local word, long, sum, rows = {}, {}, {}, 0
  for i = 1, n do word[i], long[i], sum[i] = 0, 0, 0 end
  local function measure(rs)
    for _, row in ipairs(rs) do
      rows = rows + 1
      for i, cell in ipairs(row.cells) do
        local len, w = 0, 0
        local function add(s, f)
          for part, sp in s:gmatch('(%S*)(%s*)') do
            w = w + (utf8.len(part) or #part) * f
            word[i] = math.max(word[i], w)
            if sp ~= '' then w = 0 end
            len = len + ((utf8.len(part) or #part) + #sp) * f
          end
        end
        pandoc.Blocks(cell.contents):walk {
          Str = function(el) add(el.text, 1) end,
          Code = function(el) add(el.text, 1.1) end,
          Space = function() w = 0; len = len + 1 end,
          SoftBreak = function() w = 0; len = len + 1 end,
          RawInline = function() w = 0 end, -- a break point from breakable()
        }
        long[i] = math.max(long[i], len)
        sum[i] = sum[i] + len
      end
    end
  end
  measure(t.head.rows)
  for _, body in ipairs(t.bodies) do measure(body.body) end
  local room, natural, minimum, extra = ((page or PORTRAIT) - 12 * n) / 6.3, 0, 0, 0
  local min, want = {}, {}
  for i = 1, n do
    natural = natural + long[i]
    min[i] = word[i] + 1
    want[i] = math.max(min[i], (math.min(long[i], 60) + sum[i] / rows) / 2)
    minimum, extra = minimum + min[i], extra + want[i] - min[i]
  end
  if natural <= room then return nil end
  local spare = math.max(room - minimum, 0)
  for i, cs in ipairs(t.colspecs) do
    local w = min[i] + (extra > 0 and spare * (want[i] - min[i]) / extra or 0)
    t.colspecs[i] = { cs[1], w / math.max(room, minimum) }
  end
  return t
end

local function accounts()
  local ids = {}
  for _, k in ipairs(sources.dr.keys) do
    local n = k:match('^ACCOUNT_(%d+)$')
    if n then table.insert(ids, { tonumber(n), k }) end
  end
  table.sort(ids, function(a, b) return a[1] < b[1] end)
  local rows = {}
  for _, id in ipairs(ids) do
    local f = {}
    for field in (sources.dr.vals[id[2]] .. '|'):gmatch('([^|]*)|') do
      table.insert(f, fill((field:gsub('^%s+', ''):gsub('%s+$', ''))))
    end
    if #f ~= 7 then error(id[2] .. ' in dr' .. SUFFIX .. ' needs 7 fields separated by |, has ' .. #f) end
    local br = pandoc.LineBreak()
    table.insert(rows, {
      pandoc.Inlines { pandoc.Strong(f[1]), br, pandoc.Str(f[2]) },
      pandoc.Inlines { pandoc.Str('Renews: ' .. f[3]), br, pandoc.Str('Cost: ' .. f[4]), br, pandoc.Str('Paid with: ' .. f[5]) },
      pandoc.Inlines(f[6]),
      pandoc.Inlines(f[7]),
    })
  end
  local t = table_of({ 'Account', 'Renewal', 'If cancelled, this stops', 'Action' }, { 0, 0, 0, 0 }, rows)
  return widen(t) or t
end

local function include(path)
  local f = io.open(REPO .. '/' .. path) or error('include not found: ' .. path)
  local blocks = pandoc.read(f:read('a'), 'gfm').blocks
  f:close()
  if blocks[1] and blocks[1].t == 'Header' and blocks[1].level == 1 then blocks:remove(1) end
  return blocks:walk(fill_filter):walk { Table = widen }
end

local blocks_filter = {
  Table = widen,
  Div = function(el)
    if el.attributes.include then return include(el.attributes.include) end
    if el.classes:includes('landscape') then
      local out = pandoc.Blocks { pandoc.RawBlock('latex', '\\landscapepages') }
      out:extend(el.content:walk { Table = function(t) return widen(t, LANDSCAPE) end })
      out:insert(pandoc.RawBlock('latex', '\\portraitpages'))
      return out
    end
    if el.classes:includes('accounts') then return accounts() end
    if el.classes:includes('secrets') then
      if el.attributes.source == 'dr' then return secrets(sources.dr) end
      local out = pandoc.Blocks {}
      for _, s in ipairs(services) do
        out:insert(pandoc.Header(2, pandoc.Inlines { pandoc.Code('services/' .. s .. '/.env') },
          pandoc.Attr('', { 'unnumbered', 'unlisted' }))) -- keeps the contents to one page
        out:insert(secrets(sources[s]))
      end
      return out
    end
  end,
  -- The mermaid diagram, without a "Figure 1" caption
  Figure = function(el) return el.content end,
  -- Each part starts on a new page
  Header = function(el)
    if el.level == 1 then return { pandoc.RawBlock('latex', '\\clearpage'), el } end
  end,
}

local final_filter = {
  Meta = function(m)
    m.title = pandoc.Inlines('Recovery pack: ' .. DOMAIN)
    m.subtitle = pandoc.Inlines(SUFFIX == '.env' and 'Contains passwords: keep it safe'
      or 'SAMPLE: placeholder values only')
    -- Ragged right, so a long token never pushes a justified line past the margin.
    -- \\landscapepages turns the following pages into A4 landscape, \\portraitpages back.
    m['header-includes'] = pandoc.MetaBlocks { pandoc.RawBlock('latex', [[
\AtBeginDocument{\raggedright}
\newcommand{\landscapepages}{\clearpage\pdfpagewidth=297mm \pdfpageheight=210mm
  \paperwidth=297mm \paperheight=210mm \newgeometry{layoutwidth=297mm,layoutheight=210mm,margin=2cm}}
\newcommand{\portraitpages}{\clearpage\pdfpagewidth=210mm \pdfpageheight=297mm
  \paperwidth=210mm \paperheight=297mm \restoregeometry}]]) }
    m.date = pandoc.Inlines('Printed ' .. sources.gen.vals.DATE .. ' from commit ' .. sources.gen.vals.COMMIT)
    return m
  end,
  Pandoc = function(doc)
    local refs = {}
    for ref in pairs(missing) do table.insert(refs, ref) end
    if #refs > 0 then
      table.sort(refs)
      error('No value for: ' .. table.concat(refs, ', ') .. ' (add the key to dr' .. SUFFIX .. ' or the service .env)')
    end
    return doc
  end,
}

return { fill_filter, blocks_filter, final_filter }
