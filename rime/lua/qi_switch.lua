-- C2: 小鹤双拼 / 全拼 切换。
-- 快捷键（默认 Ctrl+Shift+1，可在设置中更改）在两者间切换；界面（菜单栏、手机键盘按钮）写入 qi_schema.txt 请求切换。
-- qi_schema.txt 是"当前输入方式"的唯一记录，内容为 "<方案名> <序号>"，所有会话按它对齐。

local SCHEMAS = { "rime_frost_double_pinyin_flypy", "rime_frost" }
local DEFAULT_HOTKEYS = "Control+Shift+1 Control+Shift+exclam"

QI_SWITCH = QI_SWITCH or {}
local S = QI_SWITCH

-- C2: 快捷键可由用户设置：qi_hotkey.txt 第二行是空格分隔的 Rime 按键写法，没有该文件时用默认值。
local function hotkeys()
  local spec = DEFAULT_HOTKEYS
  local f = io.open(rime_api.get_user_data_dir() .. "/qi_hotkey.txt", "r")
  if f then
    f:read("*l")
    spec = f:read("*l") or spec
    f:close()
  end
  if spec ~= S.hotkey_spec then
    S.hotkey_spec, S.hotkeys = spec, {}
    for k in spec:gmatch("%S+") do table.insert(S.hotkeys, KeyEvent(k)) end
  end
  return S.hotkeys
end

local function is_hotkey(key)
  for _, k in ipairs(hotkeys()) do
    if key:eq(k) then return true end
  end
  return false
end

local function state_path()
  return rime_api.get_user_data_dir() .. "/qi_schema.txt"
end

local function is_ours(id)
  for _, s in ipairs(SCHEMAS) do
    if s == id then return true end
  end
  return false
end

local function read_state()
  local f = io.open(state_path(), "r")
  if not f then return nil, nil end
  local s = f:read("*a") or ""
  f:close()
  return s:match("^(%S+)%s+(%S+)")
end

local function write_state(id)
  local seq = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
  local f = io.open(state_path(), "w")
  if f then
    f:write(id, " ", seq, "\n")
    f:close()
  end
  S.target, S.seq = id, seq
end

local function apply(engine, id)
  S.applying = true
  engine:apply_schema(Schema(id))
  S.applying = false
end

local M = {}

local OPTION = "qi_flypy"

function M.init(env)
  local engine = env.engine
  local cur = engine.schema.schema_id
  -- C2: 键盘工具栏 / 方案选单上的「全拼 ⇄ 小鹤」开关，切换后下一次按键生效
  env.option_conn = engine.context.option_update_notifier:connect(function(ctx, name)
    if name ~= OPTION then return end
    local want = ctx:get_option(OPTION) and SCHEMAS[1] or SCHEMAS[2]
    if want ~= engine.schema.schema_id then write_state(want) end
  end)
  if S.applying then return end
  local id, seq = read_state()
  if S.seq == nil then
    if id and is_ours(id) then
      S.target, S.seq = id, seq
    else
      write_state(cur)
    end
    return
  end
  -- C2: 界面发来的请求尚未被处理：保留它，下一次按键时生效
  if seq ~= S.seq then return end
  -- C2: 通过方案选单等其他途径切换：记下新的输入方式
  if cur ~= S.target and is_ours(cur) then write_state(cur) end
end

function M.fini(env)
  if env.option_conn then env.option_conn:disconnect() end
end

function M.func(key, env)
  local engine = env.engine
  local cur = engine.schema.schema_id
  local id, seq = read_state()
  if id and seq ~= S.seq and is_ours(id) then
    S.target, S.seq = id, seq
  end
  if is_hotkey(key) then
    local now = S.target or cur
    local nxt = (now == SCHEMAS[1]) and SCHEMAS[2] or SCHEMAS[1]
    write_state(nxt)
    if nxt ~= cur then apply(engine, nxt) end
    return 1
  end
  if key:release() then return 2 end
  if S.target and S.target ~= cur and is_ours(S.target) then
    apply(engine, S.target)
    -- C2: 本次按键交给新的输入方式处理；旧的处理链已被替换，只能返回"已处理"或"拒绝"
    if engine:process_key(key) then return 1 end
    return 0
  end
  return 2
end

return M
