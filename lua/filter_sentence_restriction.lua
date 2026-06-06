--[[
filter_sentence_restriction.lua
2026-06-07 v8: 嚴格 Tier 2 門檻與 Tier 3 權重校正
修正：徹底隔離聯想詞，確保字典詞領先
--]]

local function utf8_len(s)
  local _, count = string.gsub(s, "[^\128-\193]", "")
  return count
end

local function is_pure_symbol(s)
  local i = 1
  local len = string.len(s)
  while i <= len do
    local b1 = string.byte(s, i)
    if b1 < 128 then
      if (b1 >= 48 and b1 <= 57) or (b1 >= 65 and b1 <= 90) or (b1 >= 97 and b1 <= 122) or (b1 == 95) or (b1 == 32) then i = i + 1
      else return true end
    else
      if b1 >= 0xE4 and b1 <= 0xE9 or b1 == 0xE3 or b1 == 0xF0 then return false end
      if b1 >= 0xC0 and b1 <= 0xDF then i = i + 2
      elseif b1 >= 0xE0 and b1 <= 0xEF then i = i + 3
      elseif b1 >= 0xF0 and b1 <= 0xF7 then i = i + 4
      else i = i + 1 end
    end
  end
  return true
end

-- 載入字典
local dict_entries = nil
local function load_dict(filename)
  if dict_entries then return end
  dict_entries = {}
  local appdata = os.getenv("APPDATA") or "C:\\Users\\kj\\AppData\\Roaming"
  local paths = { filename, appdata .. "\\Rime\\" .. filename, "C:\\Users\\kj\\AppData\\Roaming\\Rime\\" .. filename }
  local f = nil
  for _, p in ipairs(paths) do f = io.open(p, "rb"); if f then break end end
  if not f then return end
  local in_header = true
  for line in f:lines() do
    line = string.gsub(line, "[\r\n]+$", "")
    if in_header then if line == "..." then in_header = false end
    elseif not string.find(line, "^%s*#") and not string.find(line, "^%s*$") then
      local fields = {}
      for field in string.gmatch(line, "[^\t]+") do table.insert(fields, field) end
      if fields[1] and fields[2] then
        local word, code, weight = fields[1], fields[2], tonumber(fields[3]) or 0
        dict_entries[word .. "_" .. code] = { weight = weight, code = code }
        if not dict_entries[word] or weight > (dict_entries[word].weight or 0) then
          dict_entries[word] = { weight = weight, code = code }
        end
      end
    end
  end
  f:close()
end

local function compare_items(a, b)
  -- 1) 符號最後
  if a.is_symbol ~= b.is_symbol then return b.is_symbol end
  -- 2) 字根差分最優先 (包含在 Tier 3)
  if a.len_diff ~= b.len_diff then return a.len_diff < b.len_diff end
  -- 3) 品質次之
  if math.abs(a.quality - b.quality) > 1e-12 then return a.quality > b.quality end
  -- 4) 字典權重與索引
  local a_w = a.dict_weight or 0
  local b_w = b.dict_weight or 0
  if a_w ~= b_w then return a_w > b_w end
  return a.index < b.index
end

local function filter(input, env)
  load_dict("sucang.dict.yaml")
  local input_str = env.engine.context.input
  local tier1, tier2, tier3 = {}, {}, {}
  local max_output = 45
  local iterated = 0

  for cand in input:iter() do
    iterated = iterated + 1
    if iterated > 5000 then break end
    
    local text, quality, c_type = cand.text or "", cand.quality or 0, cand.type or ""
    
    -- 編碼提取：聯想詞通常沒有編碼注釋
    local cand_code = cand.comment and string.match(cand.comment, "([a-z]+)")
    
    -- 重要：如果沒有編碼注釋，這可能是聯想詞，我們給它一個極大的 len_diff
    local word_code = cand_code or ""
    local dict_info = dict_entries and (dict_entries[text .. "_" .. word_code] or dict_entries[text]) or nil
    
    -- 如果 word_code 為空（無注釋），則 len_diff 設為 99 (Tier 3 墊底)
    local len_diff = 99
    if cand_code then
      len_diff = math.abs(string.len(cand_code) - string.len(input_str))
    elseif dict_info and dict_info.code then
      len_diff = math.abs(string.len(dict_info.code) - string.len(input_str))
    end
    
    local item = { 
      cand = cand, text = text, quality = quality, type = c_type,
      len_diff = len_diff, is_symbol = is_pure_symbol(text), 
      dict_weight = dict_info and dict_info.weight or 0,
      index = iterated 
    }

    -- 🌟 v8 嚴格分層
    if quality >= 9000.0 or c_type == "custom_phrase" then
      table.insert(tier1, item)
    -- Tier 2: 只有在字典中且長度完全匹配的字，或是已知編碼且長度匹配的學習詞
    elseif len_diff == 0 and (dict_info ~= nil or c_type == "user_table") then
      table.insert(tier2, item)
    -- Tier 3: 聯想詞、長度不匹配的字典詞（前綴）、史瓦辛格等
    else
      table.insert(tier3, item)
    end

    if iterated >= 200 then break end
  end

  table.sort(tier2, compare_items)
  table.sort(tier3, compare_items)

  local yielded = 0
  for _, t in ipairs({tier1, tier2, tier3}) do
    for i = 1, #t do
      if yielded >= max_output then break end
      yield(t[i].cand)
      yielded = yielded + 1
    end
  end

  if yielded < max_output then
    for cand in input:iter() do
      if yielded >= max_output then break end
      yield(cand)
      yielded = yielded + 1
    end
  end
end

return filter
