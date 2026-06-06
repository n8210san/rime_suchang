-- filter_sentence_restriction.lua
-- 功用：極致、高效率、純粹的 3 層 (3 Tiers) 候選字智慧過濾與懶加載排序系統。
-- 100% 數據與類型驅動，依據自訂詞典的權重與原始行號進行嚴格排序。
-- 智慧字（系統拼湊句、聯想補全）未上屏過者一律進行懶加載，絕不佔用首頁，徹底解決卡頓與慢的問題。

local utf8_len_cache = {}
local function utf8_len(s)
  local cached = utf8_len_cache[s]
  if cached then
    return cached
  end
  local _, count = string.gsub(s, "[^\128-\191]", "")
  utf8_len_cache[s] = count
  return count
end

-- 檢測字串是否包含漢字、英文字母、底線或數字 (CJK or Word characters)
-- 採用 100% 原生位組級別判定演算法，無外部依賴，性能極高
local function is_cjk_or_alphanumeric(s)
  local i = 1
  local len = string.len(s)
  while i <= len do
    local b1 = string.byte(s, i)
    if b1 < 128 then
      -- ASCII 字元：英數字、底線或空白被視為普通字元 (非符號)
      if (b1 >= 48 and b1 <= 57) or   -- 0-9
         (b1 >= 65 and b1 <= 90) or   -- A-Z
         (b1 >= 97 and b1 <= 122) or  -- a-z
         b1 == 95 or b1 == 32 then    -- _ 或 空白
        return true
      end
      i = i + 1
    else
      -- 萬國碼多位組漢字字元判定
      -- CJK 統一漢字 (U+4E00 - U+9FFF): UTF-8 為 3 位組，首位組介於 0xE4 - 0xE9
      if b1 >= 0xE4 and b1 <= 0xE9 then
        if i + 2 <= len then
          local b2 = string.byte(s, i + 1)
          local b3 = string.byte(s, i + 2)
          if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
            return true
          end
        end
      end
      -- CJK 擴展 A (U+3400 - U+4DBF): UTF-8 首位組為 0xE3，次位組介於 0x90 - 0xBF
      if b1 == 0xE3 then
        if i + 2 <= len then
          local b2 = string.byte(s, i + 1)
          if b2 >= 0x90 and b2 <= 0xBF then
            return true
          end
        end
      end
      -- CJK 增補與擴展 B-H (4 位組，以 0xF0 開頭)
      if b1 == 0xF0 then
        if i + 3 <= len then
          return true
        end
      end
      -- 移動指針到下一個 UTF-8 字元
      if b1 >= 0xC0 and b1 <= 0xDF then
        i = i + 2
      elseif b1 >= 0xE0 and b1 <= 0xEF then
        i = i + 3
      elseif b1 >= 0xF0 and b1 <= 0xF7 then
        i = i + 4
      else
        i = i + 1
      end
    end
  end
  return false
end

-- 檢測字串是否完全由特殊符號、數學標點 or 幾何圖形組成
local function is_pure_symbol(s)
  return not is_cjk_or_alphanumeric(s)
end

-- 智慧純符號檢測快取，避免重複進行 UTF-8 編碼迭代
local symbol_cache = {}
local function is_pure_symbol_cached(s)
  local cached = symbol_cache[s]
  if cached ~= nil then
    return cached
  end
  local result = is_pure_symbol(s)
  symbol_cache[s] = result
  return result
end

-- 檢測字串是否包含中文漢字
local function contains_chinese(s)
  local i = 1
  local len = string.len(s)
  while i <= len do
    local b1 = string.byte(s, i)
    if b1 >= 128 then
      if b1 == 0xE3 or (b1 >= 0xE4 and b1 <= 0xE9) or b1 == 0xF0 then
        return true
      end
      if b1 >= 0xC0 and b1 <= 0xDF then
        i = i + 2
      elseif b1 >= 0xE0 and b1 <= 0xEF then
        i = i + 3
      elseif b1 >= 0xF0 and b1 <= 0xF7 then
        i = i + 4
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return false
end

-- 載入主字典所有詞彙的最高權重與最早行號
local dict_entries = {}

local function load_dict(filename)
  local appdata = os.getenv("APPDATA")
  local path = (appdata or "C:\\Users\\kj\\AppData\\Roaming") .. "\\Rime\\" .. filename
  local f = io.open(path, "rb")
  if not f then
    return
  end
  local in_header = true
  local line_num = 0
  for line in f:lines() do
    line_num = line_num + 1
    -- 移除 Windows 換行符 (\r)
    line = string.gsub(line, "[\r\n]+$", "")
    
    if in_header then
      if line == "..." then
        in_header = false
      elseif string.find(line, "\t", 1, true) then
        in_header = false
      end
    end

    if not in_header then
      -- 排除空行與註釋
      if not string.find(line, "^%s*#") and not string.find(line, "^%s*$") then
        local tab1 = string.find(line, "\t", 1, true)
        if tab1 then
          local word = string.sub(line, 1, tab1 - 1)
          local rest = string.sub(line, tab1 + 1)
          local tab2 = string.find(rest, "\t", 1, true)
          local code, weight_str
          if tab2 then
            code = string.sub(rest, 1, tab2 - 1)
            weight_str = string.sub(rest, tab2 + 1)
          else
            code = rest
            weight_str = "0"
          end
          
          if word ~= "" and code ~= "" then
            local weight = tonumber(weight_str) or 0
            -- 1. 精確的 word_code 儲存
            dict_entries[word .. "_" .. code] = { weight = weight, line = line_num }
            
            -- 2. 備用的 word 儲存 (保留最高權重)
            local existing = dict_entries[word]
            if not existing or weight > existing.weight then
              dict_entries[word] = { weight = weight, line = line_num, code = code }
            end
          end
        end
      end
    end
  end
  f:close()
end

-- 僅載入主詞典，生字表 (cangjie5.dict.yaml) 刻意不載入，使其自然留在 Tier 3
load_dict("sucang.dict.yaml")


-- 🌟 1. Tier 1 (Pinned items) 排序規則：優先按品質，後按原始順序
local function compare_tier1(a, b)
  if math.abs(a.quality - b.quality) > 1e-5 then
    return a.quality > b.quality
  end
  return a.index < b.index
end

-- 🌟 2. Tier 2 (Static Dictionary items) 排序規則：智慧自適應加權與字典原始順序
local function compare_tier2(a, b)
  -- 1) 符號降級分組比較 (非符號在前，純符號在後)
  local a_sym = a.is_symbol and 1 or 0
  local b_sym = b.is_symbol and 1 or 0
  if a_sym ~= b_sym then
    return a_sym < b_sym
  end
  
  -- 2) 字根差分桶遞增模型排序 (len_diff 越小越靠前)
  if a.len_diff ~= b.len_diff then
    return a.len_diff < b.len_diff
  end
  
  -- 3) 依據智慧自適應得分由高到低排序 (在同一個分桶內排序)
  if math.abs(a.score - b.score) > 1e-12 then
    return a.score > b.score
  end
  
  -- 4) 若分數非常接近，則依據 sucang.dict.yaml 最早出現的行號由小到大排序 (保持原始順序)
  if a.line ~= b.line then
    return a.line < b.line
  end
  
  -- 5) 穩定排序 Tie-breaker
  return a.index < b.index
end

local function filter(input, env)
  local tier1 = {}
  local tier2 = {}
  local tier3 = {}

  local input_str = env.engine.context.input
  local is_target_debug = (input_str == "g" or input_str == "gg" or input_str == "nt" or input_str == "el" or input_str == "qn" or input_str == "qnat" or input_str == "book" or input_str == "mgyp")
  
  local appdata = os.getenv("APPDATA")
  local debug_log_path = (appdata or "C:\\Users\\kj\\AppData\\Roaming") .. "\\Rime\\lua_debug.log"
  
  if is_target_debug then
    local debug_file = io.open(debug_log_path, "a")
    if debug_file then
      debug_file:write(string.format("\n--- DEBUG START FOR INPUT: %s ---\n", input_str))
      debug_file:close()
    end
  end

  -- 智慧懶加載與輸出計數設定
  local sort_threshold = 20
  local count = 0
  local total_yielded = 0
  local flushed = false

  local function flush_sorted_cands()
    if flushed then return end
    flushed = true
    
    -- 對 Tier 1 與 Tier 2 進行高速排序 (Tier 3 保持 Rime 預設順序)
    table.sort(tier1, compare_tier1)
    table.sort(tier2, compare_tier2)
    
    if is_target_debug then
      local debug_file = io.open(debug_log_path, "a")
      if debug_file then
        debug_file:write("--- AFTER CLASSIFICATION & SORTING ---\n")
        debug_file:write(string.format("Tier 1 size: %d, Tier 2 size: %d, Tier 3 size: %d\n", #tier1, #tier2, #tier3))
        debug_file:write("--- Tier 1 candidates: ---\n")
        for i = 1, #tier1 do
          debug_file:write(string.format("[%d] %s (score: %f, weight: %s, line: %s, type: %s)\n", i, tier1[i].text, tier1[i].score or 0, tostring(tier1[i].weight), tostring(tier1[i].line), tier1[i].type))
        end
        debug_file:write("--- Tier 2 candidates: ---\n")
        for i = 1, #tier2 do
          debug_file:write(string.format("[%d] %s (score: %f, weight: %s, line: %s, type: %s)\n", i, tier2[i].text, tier2[i].score or 0, tostring(tier2[i].weight), tostring(tier2[i].line), tier2[i].type))
        end
        debug_file:write("--- Tier 3 candidates (first 10 shown): ---\n")
        for i = 1, math.min(#tier3, 10) do
          debug_file:write(string.format("[%d] %s (weight: %s, line: %s, type: %s)\n", i, tier3[i].text, tostring(tier3[i].weight), tostring(tier3[i].line), tier3[i].type))
        end
        debug_file:write("--- DEBUG END ---\n")
        debug_file:close()
      end
    end
    
    -- 1. 輸出 Tier 1 (置頂)
    for i = 1, #tier1 do
      if total_yielded >= 45 then break end
      yield(tier1[i].cand)
      total_yielded = total_yielded + 1
    end
    
    -- 2. 輸出 Tier 2 (字典核心與精確字)
    for i = 1, #tier2 do
      if total_yielded >= 45 then break end
      yield(tier2[i].cand)
      total_yielded = total_yielded + 1
    end
    
    -- 3. 輸出 Tier 3 (補滿至 45 個)
    if total_yielded < 45 then
      for i = 1, #tier3 do
        if total_yielded >= 45 then break end
        yield(tier3[i].cand)
        total_yielded = total_yielded + 1
      end
    end
  end

  local safety_max_iterated = 5000
  local iterated = 0

  for cand in input:iter() do
    iterated = iterated + 1
    if iterated > safety_max_iterated then
      break
    end
    
    -- 只要總輸出已達 45 個，立刻結束遍歷，不再浪費效能
    if total_yielded >= 45 then
      break
    end
    
    local text = cand.text or ""
    local quality = cand.quality or 0
    local c_type = cand.type or ""
    
    local is_symbol = is_pure_symbol_cached(text)
    
    -- 提取候選字的編碼 (從 cand.comment 中提取字母，若無則用當前輸入)
    local cand_code = cand.comment and string.match(cand.comment, "([a-z]+)")
    local word_code = cand_code or env.engine.context.input
    
    local dict_info = nil
    if word_code then
      dict_info = dict_entries[text .. "_" .. word_code]
    end
    if not dict_info then
      dict_info = dict_entries[text]
    end
    
    -- 判定是否為未匹配的中文詞組
    local is_chinese_phrase = (utf8_len(text) >= 2) and contains_chinese(text)
    local is_unmatched_chinese_phrase = is_chinese_phrase and (dict_info == nil)
    
    -- 🌟 如果輸入長度 <= 4，且候選字是未匹配的動態中文詞組（聯想/智慧句），則完全過濾丟棄，絕不上屏！
    local should_discard = (string.len(input_str) <= 4) and is_unmatched_chinese_phrase
    
    if not should_discard then
      count = count + 1
      
      -- 計算長度加權分數 (雙軌自適應懲罰)
      local penalty = 1e-9
      if c_type == "user_table" then
        penalty = 0.01
      end
      local score = quality - (utf8_len(text) - 1) * penalty
      
      -- 計算字根差分桶 (Key Length Incremental)
      local code_len = word_code and string.len(word_code) or 0
      local input_len = string.len(input_str)
      local len_diff = math.max(0, code_len - input_len)
      
      local item = {
        cand = cand,
        text = text,
        quality = quality,
        type = c_type,
        index = count,
        len = utf8_len(text),
        is_symbol = is_symbol,
        weight = dict_info and dict_info.weight or 0,
        line = dict_info and dict_info.line or 999999,
        score = score,
        len_diff = len_diff
      }
      
      if is_target_debug then
        local debug_file = io.open(debug_log_path, "a")
        if debug_file then
          debug_file:write(string.format("[CAND %d] (accepted: %d) text: %s, type: %s, qual: %f, score: %f, comment: %s, matched_code: %s, dict_weight: %s, dict_line: %s, should_discard: %s\n",
            iterated, count, text, c_type, quality, score, tostring(cand.comment), tostring(word_code), 
            tostring(dict_info and dict_info.weight or "nil"), tostring(dict_info and dict_info.line or "nil"),
            tostring(should_discard)))
          debug_file:close()
        end
      end
      
      if count <= sort_threshold then
        -- 收集並快取前 20 個非丟棄候選字
        local is_tier1 = (quality >= 9000.0 or c_type == "custom_phrase")
        
        if is_tier1 then
          table.insert(tier1, item)
        elseif dict_info ~= nil and c_type ~= "completion" then
          table.insert(tier2, item)
        elseif string.match(text, "^[a-zA-Z%-'%.]+$") then
          table.insert(tier3, item)
        else
          table.insert(tier3, item)
        end
        
        if count == sort_threshold then
          flush_sorted_cands()
        end
      else
        -- 第 21 個候選字之後的處理
        if not flushed then
          flush_sorted_cands()
        end
        
        -- 重複安全檢查，防止多重執行流溢出
        if total_yielded >= 45 then
          break
        end
        
        local is_tier1 = (quality >= 9000.0 or c_type == "custom_phrase")
        local is_tier2 = (dict_info ~= nil and c_type ~= "completion")
        
        if is_tier1 or is_tier2 then
          -- Tier 1 和 Tier 2 隨時允許輸出，只要未滿 45
          yield(cand)
          total_yielded = total_yielded + 1
        else
          -- Tier 3 的候選字，只有在總數未滿 45 時才流式輸出
          if total_yielded < 45 then
            yield(cand)
            total_yielded = total_yielded + 1
          end
        end
      end
    else
      if is_target_debug then
        local debug_file = io.open(debug_log_path, "a")
        if debug_file then
          debug_file:write(string.format("[DISCARDED %d] text: %s, type: %s, qual: %f\n", iterated, text, c_type, quality))
          debug_file:close()
        end
      end
    end
  end

  -- 如果迭代結束仍未達到 sort_threshold 個，則在此時輸出
  if not flushed then
    flush_sorted_cands()
  end
end

return filter
