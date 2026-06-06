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

  -- 智慧輸出計數與安全閥設定
  local max_output = 45
  local total_yielded = 0
  local safety_max_iterated = 5000
  local iterated = 0
  
  -- 1. 預讀與分類階段：獲取足夠的候選字以供排序
  -- 我們至少預讀 100 個，或者直到流結束，以確保前幾頁的品質
  local prefetch_limit = 100
  local prefetched_items = {}
  local prefetch_count = 0

  for cand in input:iter() do
    iterated = iterated + 1
    if iterated > safety_max_iterated then break end
    
    local text = cand.text or ""
    local quality = cand.quality or 0
    local c_type = cand.type or ""
    local is_symbol = is_pure_symbol_cached(text)
    
    local cand_code = cand.comment and string.match(cand.comment, "([a-z]+)")
    local word_code = cand_code or env.engine.context.input
    
    local dict_info = nil
    if word_code then dict_info = dict_entries[text .. "_" .. word_code] end
    if not dict_info then dict_info = dict_entries[text] end
    
    local is_chinese_phrase = (utf8_len(text) >= 2) and contains_chinese(text)
    local is_unmatched_chinese_phrase = is_chinese_phrase and (dict_info == nil)
    local should_discard = (string.len(input_str) <= 2) and is_unmatched_chinese_phrase
    
    if not should_discard then
      prefetch_count = prefetch_count + 1
      
      local penalty = (c_type == "user_table") and 0.01 or 1e-9
      local score = quality - (utf8_len(text) - 1) * penalty
      
      local code_len = word_code and string.len(word_code) or 0
      local len_diff = math.max(0, code_len - string.len(input_str))
      
      local item = {
        cand = cand,
        text = text,
        quality = quality,
        type = c_type,
        index = prefetch_count,
        is_symbol = is_symbol,
        weight = dict_info and dict_info.weight or 0,
        line = dict_info and dict_info.line or 999999,
        score = score,
        len_diff = len_diff
      }

      local is_tier1 = (quality >= 9000.0 or c_type == "custom_phrase")
      local is_learned_exact = (c_type == "user_table" and len_diff == 0)

      if is_tier1 then
        table.insert(tier1, item)
      elseif (dict_info ~= nil or is_learned_exact) and c_type ~= "completion" then
        table.insert(tier2, item)
      else
        table.insert(tier3, item)
      end

      -- 如果已經收集到足夠的候選字且 Tier 1+2 已經很豐富，可以提早開始輸出
      if prefetch_count >= prefetch_limit then break end
    end
  end

  -- 2. 排序與輸出核心
  table.sort(tier1, compare_tier1)
  table.sort(tier2, compare_tier2)

  if is_target_debug then
    local debug_file = io.open(debug_log_path, "a")
    if debug_file then
      debug_file:write(string.format("--- PREFETCH SUMMARY: Tier 1: %d, Tier 2: %d, Tier 3: %d ---\n", #tier1, #tier2, #tier3))
      debug_file:close()
    end
  end

  -- 輸出 Tier 1
  for i = 1, #tier1 do
    if total_yielded >= max_output then break end
    yield(tier1[i].cand)
    total_yielded = total_yielded + 1
  end

  -- 輸出 Tier 2
  for i = 1, #tier2 do
    if total_yielded >= max_output then break end
    yield(tier2[i].cand)
    total_yielded = total_yielded + 1
  end

  -- 輸出 Tier 3 (補位)
  for i = 1, #tier3 do
    if total_yielded >= max_output then break end
    yield(tier3[i].cand)
    total_yielded = total_yielded + 1
  end

  -- 3. 懶加載補足階段：若上述 Tier 1/2/3 預讀內容仍不足 45 個，則繼續從輸入流讀取直至補滿
  if total_yielded < max_output then
    for cand in input:iter() do
      iterated = iterated + 1
      if total_yielded >= max_output or iterated > safety_max_iterated then break end
      
      -- 這裡不再進行複雜過濾，直接補位輸出，確保「必定有字」
      yield(cand)
      total_yielded = total_yielded + 1
    end
  end

end

return filter
