--[[
filter_sentence_restriction.lua
2026-06-07 v35: 實裝精確/n+1字根保護與 Page-3 智慧分頁懶加載系統
--]]

local dict_entries = {}
local dict_loaded = false

-- 1. 系統化字典載入
local function load_dict()
  if dict_loaded then return end
  local path = "C:\\Users\\KJ\\AppData\\Roaming\\Rime\\sucang.dict.yaml"
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
  
  local tier1_list = {}
  local tier2_buckets = {} -- buckets[0...10]
  local tier3_buckets = {} -- buckets[0...10]
  for i = 0, 10 do
    tier2_buckets[i] = {}
    tier3_buckets[i] = {}
  end
  
  local iterated = 0
  local count_high_priority = 0
  local count_tier3 = 0

  for cand in input:iter() do
    iterated = iterated + 1
    local text, quality, c_type = cand.text or "", cand.quality or 0, cand.type or ""
    local t_len = utf8_len(text)
    
    -- 獲取字典資訊
    local comment = cand.comment or ""
    local cand_code = string.match(comment, "([a-z]+)")
    local d_info = (cand_code and dict_entries[text .. "_" .. cand_code]) or dict_entries[text]
    
    -- 計算得分與分桶 (Key Length Incremental)
    local real_code_len = d_info and d_info.code_len or (cand_code and string.len(cand_code) or input_len)
    local len_diff = math.min(10, math.max(0, real_code_len - input_len))
    
    -- 判定 Tier
    local is_tier1 = (quality >= 9000.0 or c_type == "custom_phrase")
    
    -- 精確匹配 (len_diff == 0) 與 n+1 字根 (len_diff == 1)
    local is_exact = (len_diff == 0)
    local is_n_plus_1 = (len_diff == 1)
    
    -- High Priority (Tier 2) includes:
    -- 1. Exact matches (len_diff == 0)
    -- 2. n+1 completions (len_diff == 1)
    -- 3. Any dictionary/learned entry (quality >= min_tier2_quality or c_type == "user_table") that is not a long completion/sentence
    local is_tier2 = (not is_tier1) and 
                     (is_exact or is_n_plus_1 or ((quality >= min_tier2_quality or c_type == "user_table") and c_type ~= "completion")) and 
                     (c_type ~= "sentence")
    
    local penalty = (c_type == "user_table") and 0.01 or 1e-9
    local score = quality - (t_len - 1) * penalty
    
    local item = { 
      cand = cand, 
      score = score, 
      len = t_len, 
      index = iterated,
      is_exact = is_exact or (cand_code == input_str or text == input_str)
    }

    if is_tier1 then
      table.insert(tier1_list, item)
      count_high_priority = count_high_priority + 1
    elseif is_tier2 then
      table.insert(tier2_buckets[len_diff], item)
      count_high_priority = count_high_priority + 1
    else
      table.insert(tier3_buckets[len_diff], item)
      count_tier3 = count_tier3 + 1
    end

    -- 湊滿 54 個高權重候選，或者高優先權 + 低優先權滿 100 個，或迭代達 2000 次就中斷遍歷
    if count_high_priority >= 54 or (count_high_priority + count_tier3 >= 100) or iterated >= 2000 then
      break
    end
  end

  -- 1. 排序 Tier 1 列表（完全命中優先）
  table.sort(tier1_list, function(a, b)
    if a.is_exact ~= b.is_exact then return a.is_exact end
    if math.abs(a.score - b.score) > 1e-12 then return a.score > b.score end
    return a.index < b.index
  end)

  -- 2. 排序 Tier 2 桶子
  local ordered_high_priority = {}
  -- 複製 Tier 1 進來
  for _, it in ipairs(tier1_list) do
    table.insert(ordered_high_priority, it)
  end
  -- 依序排序並合併 Tier 2 的桶子
  for d = 0, 10 do
    local b = tier2_buckets[d]
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
      table.insert(ordered_high_priority, it)
    end
  end

  -- 3. 排序 Tier 3 桶子並合併成 ordered_tier3
  local ordered_tier3 = {}
  for d = 0, 10 do
    local b = tier3_buckets[d]
    table.sort(b, function(a, b)
      if math.abs(a.score - b.score) > 1e-12 then return a.score > b.score end
      return a.index < b.index
    end)
    for _, it in ipairs(b) do
      table.insert(ordered_tier3, it)
    end
  end

  -- 4. 輸出與 Page-3 (27 字) 智慧分頁懶加載
  local yielded = 0
  local total_high = #ordered_high_priority

  if total_high > 27 then
    -- 情況 A：HighPriority 大於 3 頁 (27 個候選字)
    -- 前 3 頁（1~27 位）嚴格只輸出 HighPriority，保證常用字不受 Tier 3 雜訊干擾
    for i = 1, 27 do
      yield(ordered_high_priority[i].cand)
      yielded = yielded + 1
    end
    -- 自第 28 位起，將賸餘的 HighPriority 以及 Tier 3 一併加載，上限提高至 54
    for i = 28, total_high do
      if yielded >= 54 then break end
      yield(ordered_high_priority[i].cand)
      yielded = yielded + 1
    end
    for _, it in ipairs(ordered_tier3) do
      if yielded >= 54 then break end
      yield(it.cand)
      yielded = yielded + 1
    end
  else
    -- 情況 B：HighPriority 不足或剛好 3 頁
    -- 直接將 HighPriority 輸出
    for _, it in ipairs(ordered_high_priority) do
      yield(it.cand)
      yielded = yielded + 1
    end
    -- 後方直接拼接 Tier 3 補滿，上限維持 45 個
    for _, it in ipairs(ordered_tier3) do
      if yielded >= 45 then break end
      yield(it.cand)
      yielded = yielded + 1
    end
  end
end

return filter
