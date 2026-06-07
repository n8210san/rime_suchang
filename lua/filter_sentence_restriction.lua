--[[
filter_sentence_restriction.lua
2026-06-07 v34: 嚴格遵循 MEMORY.md 規範的 3-Tier 動態分桶系統
--]]

local dict_entries = {}
local dict_loaded = false

-- 1. 系統化字典載入
local function load_dict()
  if dict_loaded then return end
  local path = "C:\\Users\\kj\\AppData\\Roaming\\Rime\\sucang.dict.yaml"
  local f = io.open(path, "rb")
  if not f then f = io.open("sucang.dict.yaml", "rb") end
  if not f then return end

  local in_header = true
  for line in f:lines() do
    line = string.gsub(line, "[\r\n]+$", "")
    if in_header then
      if line == "..." then in_header = false end
    elseif not string.find(line, "^%s*#") and not string.find(line, "^%s*$") then
      local tab1 = string.find(line, "\t", 1, true)
      if tab1 then
        local word = string.sub(line, 1, tab1 - 1)
        local rest = string.sub(line, tab1 + 1)
        local tab2 = string.find(rest, "\t", 1, true)
        local code = tab2 and string.sub(rest, 1, tab2 - 1) or rest
        local weight = tonumber(tab2 and string.sub(rest, tab2 + 1) or "0") or 0
        -- 儲存精確碼與權重
        dict_entries[word .. "_" .. code] = { code_len = string.len(code), weight = weight }
        if not dict_entries[word] or weight > dict_entries[word].weight then
          dict_entries[word] = { code_len = string.len(code), weight = weight }
        end
      end
    end
  end
  f:close()
  dict_loaded = true
end

local function utf8_len(s)
  local _, count = string.gsub(s, "[^\128-\191]", "")
  return count
end

function filter(input, env)
  if not dict_loaded then load_dict() end

  local input_str = env.engine.context.input
  local input_len = string.len(input_str)
  local initial_quality = 200.0
  local min_tier2_quality = initial_quality + 1e-8
  
  local tier1 = {}
  local buckets = {} -- buckets[0...10]
  for i = 0, 10 do buckets[i] = {} end
  
  local max_output = 45
  local iterated = 0
  local count_valid = 0

  for cand in input:iter() do
    iterated = iterated + 1
    local text, quality, c_type = cand.text or "", cand.quality or 0, cand.type or ""
    local t_len = utf8_len(text)
    
    -- 獲取字典資訊
    local comment = cand.comment or ""
    local cand_code = string.match(comment, "([a-z]+)")
    local d_info = (cand_code and dict_entries[text .. "_" .. cand_code]) or dict_entries[text]
    
    -- 判定 Tier
    local is_tier1 = (quality >= 9000.0 or c_type == "custom_phrase")
    local is_tier2 = (not is_tier1) and (quality >= min_tier2_quality or c_type == "user_table") and 
                     (c_type ~= "completion" and c_type ~= "sentence")
    
    -- 計算得分與分桶 (Key Length Incremental)
    local real_code_len = d_info and d_info.code_len or (cand_code and string.len(cand_code) or input_len)
    local len_diff = math.min(10, math.max(0, real_code_len - input_len))
    
    local penalty = (c_type == "user_table") and 0.01 or 1e-9
    local score = quality - (t_len - 1) * penalty
    
    local item = { cand = cand, score = score, len = t_len, index = iterated }

    if is_tier1 then
      table.insert(tier1, item)
      count_valid = count_valid + 1
    else
      -- Tier 2 和 Tier 3 進入分桶模型
      table.insert(buckets[len_diff], item)
      if is_tier2 then count_valid = count_valid + 1 end
    end

    -- 依照 MEMORY.md：凑滿 45 個有效候選字即中斷
    if count_valid >= max_output or iterated >= 2000 then break end
  end

  -- 排序與輸出
  local yielded = 0
  
  -- 輸出 Tier 1
  table.sort(tier1, function(a, b) return a.score > b.score end)
  for _, it in ipairs(tier1) do
    if yielded >= max_output then break end
    yield(it.cand); yielded = yielded + 1
  end

  -- 按桶輸出
  for d = 0, 10 do
    if yielded >= max_output then break end
    local b = buckets[d]
    table.sort(b, function(a, b)
      -- 桶內：連打優先邏輯
      if input_len >= 3 then
        local a_s = (a.len == 2) and 2 or (a.len == 1 and 1 or 0)
        local b_s = (b.len == 2) and 2 or (b.len == 1 and 1 or 0)
        if a_s ~= b_s then return a_s > b_s end
      else
        local a_s = (a.len == 1) and 2 or (a.len == 2 and 1 or 0)
        local b_s = (b.len == 1) and 2 or (b.len == 2 and 1 or 0)
        if a_s ~= b_s then return a_s > b_s end
      end
      if math.abs(a.score - b.score) > 1e-12 then return a.score > b.score end
      return a.index < b.index
    end)
    for _, it in ipairs(b) do
      if yielded >= max_output then break end
      yield(it.cand); yielded = yielded + 1
    end
  end
end

return filter
