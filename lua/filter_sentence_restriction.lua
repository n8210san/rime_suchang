--[[
filter_sentence_restriction.lua
2026-06-07 v21: 物理字數階梯排序 (Physical Length Ladder)
修正：廢除類型偏見，單字(1) > 短詞(2) > 長詞(3+) 絕對鎖死
--]]

local function utf8_len(s)
  local _, count = string.gsub(s, "[^\128-\191]", "")
  return count
end

local function filter(input, env)
  local input_str = env.engine.context.input
  
  -- v21 物理長度分層
  local t1, t2, t3, t4 = {}, {}, {}, {}
  local max_output = 45
  local iterated = 0
  local prefetch_limit = 200

  for cand in input:iter() do
    iterated = iterated + 1
    if iterated > 5000 then break end
    
    local text, quality, c_type = cand.text or "", cand.quality or 0, cand.type or ""
    local t_len = utf8_len(text)
    local item = { cand = cand, quality = quality, len = t_len, index = iterated }

    -- 🌟 v21 物理分層邏輯：字數為王
    if quality >= 9000.0 or c_type == "custom_phrase" then
      table.insert(t1, item)
    elseif t_len == 1 then
      -- Tier 2: 所有的單字 (誠/中/帳/記/𧥤)
      table.insert(t2, item)
    elseif t_len == 2 then
      -- Tier 3: 所有的二字短詞 (帳密/確認)
      table.insert(t3, item)
    else
      -- Tier 4: 三字以上長詞 (史瓦辛格/調研報告/設計方案)
      table.insert(t4, item)
    end

    if iterated >= prefetch_limit then break end
  end

  -- 排序邏輯：同層內按品質
  local function compare_v21(a, b)
    if math.abs(a.quality - b.quality) > 1e-12 then
      return a.quality > b.quality
    end
    return a.index < b.index
  end

  table.sort(t2, compare_v21)
  table.sort(t3, compare_v21)
  table.sort(t4, compare_v21)

  -- 統一輸出
  local total_yielded = 0
  for _, t in ipairs({t1, t2, t3, t4}) do
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
