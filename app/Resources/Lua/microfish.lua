-- Microfish product logic. Loaded by the user's init.lua (Application Support/Microfish),
-- so an app update changes behaviour without touching the user's files.
-- Reads settings.lua and shortcuts.lua from MICROFISH_SUPPORT; writes navigator.tsv and
-- navigator.intent to MICROFISH_RUNTIME. The engine exports both (and MICROFISH_RESOURCES).
local SUPPORT=os.getenv("MICROFISH_SUPPORT")
local RUNTIME=os.getenv("MICROFISH_RUNTIME")
assert(SUPPORT and RUNTIME,"Microfish: MICROFISH_SUPPORT and MICROFISH_RUNTIME must be set by the engine")
local trialSettings=assert(loadfile(SUPPORT.."/settings.lua"))()
paneru.setup(trialSettings)

local intent_path=RUNTIME.."/navigator.intent"
local function intent(value)
 local f=io.open(intent_path..".tmp","w")
 if f then f:write(value); f:close(); os.rename(intent_path..".tmp",intent_path) end
end
local navigation=assert(loadfile(SUPPORT.."/shortcuts.lua"))()
local function effective_row_count(active, workspaces)
 local count=navigation.row_count
 for _,row in ipairs(workspaces or paneru.query_workspaces()) do
  if row.native_workspace_id==active.native_workspace_id then count=math.max(count,row.number or 1) end
 end
 return count
end
local function row_action(action)
 local direction=action.id:match("north$") and "north" or "south"
 if not navigation.rows_enabled then
  if action.id:match("^row_") then paneru.run("window focus "..direction); intent("show")
  elseif action.id:match("^move_row_") then paneru.run("window swap "..direction); intent("show") end
  return
 end
 local active=paneru.query_active()
 local current=active.virtual_workspace_number or 1
 local target=current+(direction=="north" and -1 or 1)
 if action.id:match("^row_") then
  paneru.run("window row "..direction)
 elseif target>=1 and target<=effective_row_count(active) then paneru.run(action.command) end
 intent("row")
end
for _,action in ipairs(navigation.bindings) do
 if action.chord~="" then
  paneru.bind(action.chord,function(ws)
   if navigation.rows_enabled and (action.id=="focus_j" or action.id=="focus_k") then
    row_action({id=action.id=="focus_j" and "row_south" or "row_north"})
   elseif action.id:match("^row_") or action.id:match("^move_row_") or action.id:match("^move_column_") then
    row_action(action)
   elseif action.id=="stack_right" or action.id=="stack_left" then
    local id=ws:focused(); if not id then return end
    local target
    if action.id=="stack_right" then target=ws:east(id) else target=ws:west(id) end
    if target then return ws:stack(id,target) end
   elseif action.id:match("^swap_column_") then
    local i=tonumber(action.id:match("(%d+)$"));local cols=ws:columns();local id=ws:focused()
    if cols[i] and cols[i][1] and id then return ws:swap(id,cols[i][1]) end
   else
    paneru.run(action.command)
    if action.id:match("^focus_") or action.id:match("^swap_") then intent("show") end
   end
  end)
 end
end
local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]"," ")) end
-- Logical overview: retain strip order/widths rather than parked hidden frames.
local function publish_spatial(lines,ws,active)
 if not ws.overview then return end
 local overview=ws:overview()
 if not overview or not overview.display then return end
 local display=overview.display
 local viewport_x=0
 local viewport_height=math.max(1,display.height or 1)
 local anchor=nil
 for _,row in ipairs(overview.rows or {}) do
  table.insert(lines,"spatialrow\t"..row.number)
  local x=0
  for column_index,column in ipairs(row.columns or {}) do
   local members=column.windows or {}
   local selected=members[(column.selected or 0)+1] or members[1]
   local tabbed=(column.tab_bar_height or 0)>0 or column.kind=="tabs"
   local width=math.max(1,(selected and selected.frame and selected.frame.width) or (column.width_ratio or 1)*(display.width or 1))
   local total=0
   for _,w in ipairs(members) do
    local h=math.max(1,(w.frame and w.frame.height) or display.height or 1)
    total=tabbed and math.max(total,h) or total+h
   end
   total=math.max(1,total)
   local y=0
   for _,w in ipairs(members) do
    local h=math.max(1,(w.frame and w.frame.height) or display.height or 1)
    table.insert(lines,table.concat({"spatial",row.number,column_index,w.id,x,tabbed and 0 or y,width,h,tabbed and 1 or 0,selected and selected.id or 0,clean(w.app_name),clean(w.bundle_id),clean(w.title)},"\t"))
    if row.active and w.frame then
     local visible=w.frame.x+(w.frame.width or 0)>(display.x or 0)+8 and w.frame.x<(display.x or 0)+(display.width or 1)-8
     if w.focused or (not anchor and visible) then
      anchor={x=x-w.frame.x+(display.x or 0),focused=w.focused}
     end
    end
    if not tabbed then y=y+h end
   end
   x=x+width+((tabbed and trialSettings.options.tab_style=="side") and 40 or 0)+2*((trialSettings.windows.spacing or {}).horizontal_padding or 0)
  end
 end
 if anchor then viewport_x=anchor.x end
 table.insert(lines,table.concat({"spatialmeta",active.virtual_workspace_number or 1,viewport_x,0,display.width or 1,viewport_height,tonumber(active.focused_window_id) or tonumber(ws:focused()) or 0},"\t"))
end

local tabs_visible=true
local last_published=nil
local function publish(event,ws)
 local active=paneru.query_active()
 local lines={tostring(ws:focused() or 0).."\t"..tostring(active.display_id or 0).."\t"..(tabs_visible and "1" or "0")}
 local info=ws:column_info()
 for index,column in ipairs(ws:columns()) do
  local meta=info[index] or {}
  local selected=meta.windows and meta.windows[(meta.selected or 0)+1]
  local selected_id=selected and selected.id or column[1] or 0
  for _,id in ipairs(column) do
   local w=ws:window(id)
   if w then table.insert(lines,table.concat({id,index,clean(w.app_name),clean(w.bundle_id),clean(w.title),meta.tab_bar_height or 0,selected_id},"\t")) end
  end
 end
 if navigation.rows_enabled then
  local workspaces=paneru.query_workspaces()
  local row_count=effective_row_count(active,workspaces)
  table.insert(lines,table.concat({"#rows",active.virtual_workspace_number or 1,row_count},"\t"))
  local summaries={}
  for _,row in ipairs(workspaces) do
   if row.native_workspace_id==active.native_workspace_id then
    local count=0;local apps={};local seen={}
    for _,window in ipairs(row.windows) do
     if not window.floating then
      count=count+1
      if not seen[window.app_name] then table.insert(apps,clean(window.app_name));seen[window.app_name]=true end
     end
    end
    summaries[row.number]={count,table.concat(apps,", ")}
   end
  end
  for i=1,row_count do
   local info=summaries[i] or {0,"Empty"}
   table.insert(lines,table.concat({"#row",i,info[1],info[2]},"\t"))
  end
 end
 publish_spatial(lines,ws,active)
 local path=RUNTIME.."/navigator.tsv"
 local content=table.concat(lines,"\n")
 -- Identical snapshots would only make the helper reparse and redraw.
 if content==last_published then
  local existing=io.open(path,"r")
  if existing then existing:close(); return end
 end
 local f=io.open(path..".tmp","w")
 if f then f:write(content); f:close(); os.rename(path..".tmp",path); last_published=content end
end
for _,event in ipairs({"window_focused","window_spawned","window_destroyed","space_changed","layout_changed","window_title_changed","window_minimized","window_deminimized","display_changed"}) do
 paneru.on(event,publish)
end
-- Only navigation input opens the navigator; focus changes only refresh data.
-- Sub-second clock for throttling HUD intents (os.time counts whole seconds, so a
-- 1 s throttle made a long swipe blink the HUD at 1 Hz). LuaJIT's ffi is loaded
-- with the standard libraries; without it this falls back to os.time.
local now=os.time
do
 local ok,ffi=pcall(require,"ffi")
 if ok and ffi then
  pcall(ffi.cdef,"typedef struct { long tv_sec; long tv_nsec; } microfish_timespec; int clock_gettime(int clock_id, microfish_timespec *tp);")
  local ok_ts,ts=pcall(ffi.new,"microfish_timespec")
  if ok_ts then
   local CLOCK_MONOTONIC=6
   local function monotonic() ffi.C.clock_gettime(CLOCK_MONOTONIC,ts); return tonumber(ts.tv_sec)+tonumber(ts.tv_nsec)*1e-9 end
   if pcall(monotonic) then now=monotonic end
  end
 end
end
local INTENT_INTERVAL=0.1
-- Swipes tell the minimap where the fingers are: "swipe" on a contact's first movement,
-- "swiping" while it moves (throttled), "lift" when the fingers leave. Modifier-scroll writes "scroll".
-- touching: a contact is open (only touchpad_up closes it, so a lift is never lost). fresh: a new
-- touch began, so the next movement is a "swipe" even if the last lift never came.
local last_swipe, last_scroll = -math.huge, -math.huge
local touching, fresh, scrolled = false, false, false
paneru.on("swipe",function(event,ws)
 if event.fingers ~= trialSettings.swipe.gesture.fingers_count then return end
 local first = not touching or fresh
 touching=true; fresh=false
 local t=now()
 if first or t-last_swipe>=INTENT_INTERVAL then
  last_swipe=t
  pcall(publish,event,ws)
  intent(first and "swipe" or "swiping")
 end
end)
paneru.on("scroll",function(event,ws)
 local first = not scrolled
 scrolled=true
 local t=now()
 if first or t-last_scroll>=INTENT_INTERVAL then
  last_scroll=t
  publish(event,ws)
  intent("scroll")
 end
end)
paneru.on("touchpad_down",function() fresh=true end)
-- The lift goes out first: the HUD's dismissal must not wait on (or be lost to) the snapshot.
paneru.on("touchpad_up",function(event,ws)
 scrolled=false
 if touching then touching=false; fresh=false; intent("lift"); pcall(publish,event,ws) end
end)
paneru.on("mouse_down",function() scrolled=false; intent("dismiss") end)


-- Bars leave Mission Control and Show Desktop unobstructed.
for _,event in ipairs({"mission_control_show_all_windows","mission_control_show_front_windows","mission_control_show_desktop"}) do
 paneru.on(event,function(e,ws) tabs_visible=false; publish(e,ws) end)
end
paneru.on("mission_control_exit",function(e,ws) tabs_visible=true; publish(e,ws) end)
