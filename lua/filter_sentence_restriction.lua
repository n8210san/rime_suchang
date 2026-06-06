--[[
filter_sentence_restriction.lua
2026-06-07 v22: 連打優先排序引擎 (Phrase-First Engine)
目標：帳密/很多(2字) > 單字 > 生字/補全
--]]

local function utf8_len(s)
  local _, count = string.gsub(s, "[^\128-\191]", "")
  return count
end

local function filter(input, env)
  local input_str = env.engine.context.input
  local input_len = string.len(input_str)
  
  -- v22 分層：Tier 2 包含連打詞與字典字，Tier 3 為生字與聯想
  local t1, t2, t3 = {}, {}, {}
  local max_output = 45
  local iterated = 0
  local prefetch_limit = 200

  for cand in input:iter() do
    iterated = iterated + 1
    if iterated > 5000 then break end
    
    local text, quality, c_type = cand.text or "", cand.quality or 0, cand.type or ""
    local t_len = utf8_len(text)
    local item = { cand = cand, quality = quality, len = t_len, index = iterated }

    -- 🌟 v22 精確分層
    if quality >= 9000.0 or c_type == "custom_phrase" then
      table.insert(t1, item)
    elseif c_type == "completion" or (c_type == "sentence" and t_len > 3) then
      -- Tier 3: 生字 (completion) 與 系統長句子
      table.insert(t3, item)
    else
      -- Tier 2: 字典詞、已選詞、以及短的造句 (帳密)
      table.insert(t2, item)
    end

    if iterated >= prefetch_limit then break end
  end

  -- 🌟 v22 排序：連打優先 (Phrase > Single)
  local function compare_v22(a, b)
    if input_len >= 3 then
      -- 長輸入時：2字詞 > 1字詞
      local a_score = (a.len == 2) and 2 or (a.len == 1 and 1 or 0)
      local b_score = (b.len == 2) and 2 or (b.len == 1 and 1 or 0)
      if a_score ~= b_score then return a_score > b_score end
    else
      -- 短輸入時：1字詞 > 2字詞
      local a_score = (a.len == 1) and 2 or (a.len == 2 and 1 or 0)
      local b_score = (b.len == 1) and 2 or (b.len == 2 and 1 or 0)
      if a_score ~= b_score then return a_score > b_score end
    end
    
    if math.abs(a.quality - b.quality) > 1e-12 then
      return a.quality > b.quality
    end
    return a.index < b.index
  end

  table.sort(t2, compare_v22)
  table.sort(t3, compare_v22)

  -- 統一輸出
  local total_yielded = 0
  for _, t in ipairs({t1, t2, t3}) do
    for i = 1, #t do
      if total_yielded >= max_output then break end
      yield(t[i].cand)
      total_yielded = total_yielded + 1
    end
  end

  -- 補位
  if total_yielded < max_output then
    for cand in input:iter() do
      if total_yielded >= max_output then break end
      yield(cand)
      total_yielded = total_yielded + 1
    end
  end
end

return filter
