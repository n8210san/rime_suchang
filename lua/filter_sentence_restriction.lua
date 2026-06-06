--[[
filter_sentence_restriction.lua
2026-06-07 v29: 修正連打優先級與造句分層
解決：lvju 下「帳密」排在「史瓦辛格」後面的問題。
核心：將 2-3 字造句 (sentence) 納入 Tier 2 + 嚴格精確匹配判定。
--]]

local function utf8_len(s)
  local _, count = string.gsub(s, "[^\128-\191]", "")
  return count
end

local function filter(input, env)
  local input_str = env.engine.context.input
  local input_len = string.len(input_str)
  
  local t1, t2, t3 = {}, {}, {}
  local max_output = 45
  local iterated = 0
  
  -- 收集目標：45 個高品質候選字
  local target_count = 45 
  local safety_limit = 800 -- 縮短預讀以確保流暢

  for cand in input:iter() do
    iterated = iterated + 1
    
    local text, quality, c_type = cand.text or "", cand.quality or 0, cand.type or ""
    local t_len = utf8_len(text)
    
    -- 提取註釋中的編碼
    local comment = cand.comment or ""
    local cand_code = string.match(comment, "([a-z]+)")
    
    -- 🌟 判定精確匹配 (len_diff = 0)
    local is_exact = (cand_code == input_str)
    -- 如果是單字且沒有註釋，且輸入長度很短(1-2)，通常是字典精確匹配
    if not is_exact and comment == "" and t_len == 1 and input_len <= 2 then
      is_exact = true
    end

    local item = { 
      cand = cand, 
      quality = quality, 
      len = t_len, 
      index = iterated,
      is_exact = is_exact
    }

    -- 🌟 3-Tier Pipeline 分類 (修正版)
    local is_short_phrase = (t_len >= 2 and t_len <= 3)
    
    if quality >= 9000.0 or c_type == "custom_phrase" then
      table.insert(t1, item)
    elseif is_exact or (c_type ~= "completion" and (c_type ~= "sentence" or is_short_phrase)) then
      -- Tier 2: 精確匹配 OR 字典字 OR 短造句 (帳密)
      table.insert(t2, item)
    else
      -- Tier 3: 聯想補全 (史瓦辛格) 或 長句子
      table.insert(t3, item)
    end

    -- 只要收集滿 45 個高品質候選字就停止
    if #t1 + #t2 >= target_count or iterated >= safety_limit then
      break
    end
  end

  -- 🌟 Tier 內排序邏輯
  local function compare_v29(a, b)
    -- 1. 精確匹配絕對優先
    if a.is_exact ~= b.is_exact then return a.is_exact end
    
    -- 2. 長輸入下的連打優先級 (lvju -> 帳密 > 帳)
    if input_len >= 3 then
      local a_s = (a.len == 2) and 2 or (a.len == 1 and 1 or 0)
      local b_s = (b.len == 2) and 2 or (b.len == 1 and 1 or 0)
      if a_s ~= b_s then return a_s > b_s end
    else
      -- 短輸入：1字詞優先
      local a_s = (a.len == 1) and 2 or (a.len == 2 and 1 or 0)
      local b_s = (b.len == 1) and 2 or (b.len == 2 and 1 or 0)
      if a_s ~= b_s then return a_s > b_s end
    end
    
    -- 3. 品質排序
    if math.abs(a.quality - b.quality) > 1e-12 then return a.quality > b.quality end
    return a.index < b.index
  end

  table.sort(t2, compare_v29)
  table.sort(t3, compare_v29)

  -- 統一輸出
  local total = 0
  for _, t in ipairs({t1, t2, t3}) do
    for i = 1, #t do
      if total >= max_output then break end
      yield(t[i].cand)
      total = total + 1
    end
  end

  -- 懶加載補位
  if total < max_output then
    for cand in input:iter() do
      iterated = iterated + 1
      if total >= max_output or iterated >= 1500 then break end
      yield(cand)
      total = total + 1
    end
  end
end

return filter
