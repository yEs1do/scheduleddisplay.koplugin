-- Run with LuaJIT from the repository root. KOREADER_DIR must contain the
-- upstream generic powerd and AutoDim modules (see .github/workflows/test.yml).
-- Only hardware, widgets, settings and the clock are mocked; the competing
-- AutoDim resume callback and the public PowerD setters run unmodified.
local koreader = assert(os.getenv("KOREADER_DIR"), "Set KOREADER_DIR to a KOReader source directory")
local plugin_main = os.getenv("PLUGIN_MAIN") or "scheduleddisplay.koplugin/main.lua"
local unpack = table.unpack or unpack
local timestamp, wall_minute, queue, writes, night, settings
local powerd, device, ui
local function eq(actual, expected, context)
    assert(actual == expected, (context or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local Widget = {}
function Widget:extend(o) self.__index = self; return setmetatable(o or {}, self) end
function Widget:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end
local manager = { event_hook = { registerWidget = function() end } }
function manager:scheduleIn(delay, fn, ...)
    queue[#queue+1] = { at=timestamp+delay, fn=fn, args={...} }
end
function manager:unschedule(fn)
    for i=#queue,1,-1 do if queue[i].fn == fn then table.remove(queue,i) end end
end
function manager:getElapsedTimeSinceBoot() return timestamp end
function manager:show() end
function manager:close() end
function manager:broadcastEvent() end
local function advance(seconds)
    local finish = timestamp + seconds
    while true do
        local index
        for i,job in ipairs(queue) do
            if job.at <= finish and (not index or job.at < queue[index].at) then index=i end
        end
        if not index then break end
        local job=table.remove(queue,index)
        timestamp=job.at
        job.fn(unpack(job.args))
    end
    timestamp=finish
end
local gettext=setmetatable({ pgettext=function(_,s) return s end }, {__call=function(_,s) return s end})
local modules = {
    ["ui/event"]={new=function(_,name,value) return {name=name,value=value} end},
    ["ui/uimanager"]=manager,
    ["ui/widget/container/widgetcontainer"]=Widget,
    ["ui/time"]={now=function() return timestamp end,s=function(n) return n end,to_s=function(n) return n end},
    ["optmath"]={round=function(n) return math.floor(n+.5) end},
    ["ffi/util"]={template=function(s) return s end},
    ["logger"]={dbg=function() end},
    ["scheduleddisplay_gettext"]=gettext, ["gettext"]=gettext,
    ["datastorage"]={getSettingsDir=function() return "." end},
    ["luasettings"]={}, ["scheduleddisplay_updater"]={}, ["datetime"]={},
}
for _,name in ipairs({"infomessage","confirmbox","radiobuttonwidget","spinwidget","trapwidget"}) do
    modules["ui/widget/"..name]=Widget
end
for name,value in pairs(modules) do package.loaded[name]=value end
os.date=function() return {hour=math.floor(wall_minute/60),min=wall_minute%60,sec=0} end

local function setup(options)
    options=options or {}
    timestamp,wall_minute,queue,writes,night=0,20*60,{},{},false
    settings={autodim_starttime_minutes=5,autodim_duration_seconds=5,autodim_fraction=20}
    G_reader_settings={
        readSetting=function(_,key,default) if settings[key]~=nil then return settings[key] end return default end,
    }
    local hardware_b,hardware_w=18,25
    device={
        hasFrontlight=function() return options.frontlight~=false end,
        hasNaturalLight=function() return options.warmth~=false end,
        hasEinkScreen=function() return true end,
        getPowerDevice=function() return powerd end,
        screen={toggleNightMode=function() end},
    }
    package.loaded.device=device
    local BasePowerD=dofile(koreader.."/frontend/device/generic/powerd.lua")
    powerd=BasePowerD:new{
        device=device,fl_min=0,fl_max=24,fl_warmth_min=0,fl_warmth_max=24,
        frontlightIntensityHW=function() return hardware_b end,
        frontlightWarmthHW=function() return hardware_w end,
        setIntensityHW=function(self,value)
            hardware_b=value
            writes[#writes+1]=value
            self:_decideFrontlightState()
        end,
        setWarmthHW=function(_,value) hardware_w=value end,
    }
    device.powerd=powerd
    powerd:UIManagerReady(manager)
    ui={menu={registerToMainMenu=function() end},handleEvent=function(_,event)
        if event.name=="SetNightMode" then night=event.value end
    end}
    if options.autodim~=false and options.frontlight~=false then
        ui.autodim=dofile(koreader.."/plugins/autodim.koplugin/main.lua"):new{ui=ui}
    end
    local Scheduled=dofile(plugin_main)
    local plugin=Scheduled:extend{
        ui=ui,enabled=true,smooth=true,duration=5,
        schedule={{time=0,brightness=50,warmth=50,night_mode="off"}},
        settings={saveSetting=function() end,flush=function() end},
    }
    return plugin,ui.autodim
end
local function dim_and_suspend(plugin,autodim)
    advance(306)
    eq(powerd:frontlightIntensity(),4,"AutoDim idle brightness")
    eq(autodim.autodim_save_fl,18,"AutoDim saved brightness")
    autodim:_onSuspend()
    plugin:onSuspend()
end
local failures,count=0,0
local function test(name,fn)
    count=count+1
    local ok,err=pcall(fn)
    if ok then print("ok "..count.." - "..name)
    else failures=failures+1; print("not ok "..count.." - "..name.."\n  "..tostring(err)) end
end

for _,order in ipairs({"autodim first","schedule first"}) do
    test("wake survives delayed AutoDim restore: "..order,function()
        local p,a=setup(); dim_and_suspend(p,a)
        if order=="autodim first" then a:_onResume(); p:onResume()
        else p:onResume(); a:_onResume() end
        eq(powerd:frontlightIntensity(),12,"immediate scheduled brightness")
        eq(powerd:toNativeWarmth(powerd:frontlightWarmth()),12,"immediate warmth")
        advance(2)
        eq(powerd:frontlightIntensity(),12,"brightness after delayed restore")
        eq(a.trap_widget,nil,"AutoDim still closes its input trap")
    end)
end
test("wake brightness zero survives delayed restore",function()
    local p,a=setup(); dim_and_suspend(p,a); p.schedule[1].brightness=0
    a:_onResume(); p:onResume(); advance(2)
    eq(powerd:frontlightIntensity(),0); eq(powerd:isFrontlightOn(),false)
end)
test("matching dimmed brightness still retires the stale restore",function()
    local p,a=setup(); dim_and_suspend(p,a); p.schedule[1].brightness=17
    a:_onResume(); p:onResume(); advance(2); eq(powerd:frontlightIntensity(),4)
end)
test("manual brightness after resume is preserved",function()
    local p,a=setup(); dim_and_suspend(p,a); a:_onResume(); p:onResume()
    powerd:setIntensity(7); advance(2); eq(powerd:frontlightIntensity(),7)
end)
test("manual warmth after resume is preserved",function()
    local p,a=setup(); dim_and_suspend(p,a); a:_onResume(); p:onResume()
    powerd:setWarmth(powerd:fromNativeWarmth(3)); advance(2)
    eq(powerd:toNativeWarmth(powerd:frontlightWarmth()),3)
end)
test("disabled scheduler leaves AutoDim restoration alone",function()
    local p,a=setup(); dim_and_suspend(p,a); p.enabled=false
    a:_onResume(); p:onResume(); eq(a.autodim_save_fl,18)
    advance(2); eq(powerd:frontlightIntensity(),18)
end)
test("empty schedule leaves AutoDim restoration alone",function()
    local p,a=setup(); dim_and_suspend(p,a); p.schedule={}
    a:_onResume(); p:onResume(); eq(a.autodim_save_fl,18)
    advance(2); eq(powerd:frontlightIntensity(),18)
end)
test("unmanaged brightness leaves AutoDim restoration alone",function()
    local p,a=setup(); dim_and_suspend(p,a); p.schedule[1].brightness="unchanged"
    a:_onResume(); p:onResume(); eq(a.autodim_save_fl,18)
    eq(powerd:toNativeWarmth(powerd:frontlightWarmth()),12)
    advance(2); eq(powerd:frontlightIntensity(),18)
end)
test("inherited brightness and midnight schedule are applied",function()
    local p,a=setup(); dim_and_suspend(p,a)
    p.schedule={{time=420,brightness=75,warmth=25,night_mode="off"},
                {time=1080,brightness=50,warmth=50,night_mode="unchanged"},
                {time=1380,brightness="unchanged",warmth=75,night_mode="on"}}
    wall_minute=10; a:_onResume(); p:onResume(); advance(2)
    eq(powerd:frontlightIntensity(),12); eq(night,true)
    eq(powerd:toNativeWarmth(powerd:frontlightWarmth()),18)
end)
test("wake works without AutoDim",function()
    local p=setup{autodim=false}; p:onResume(); advance(2)
    eq(powerd:frontlightIntensity(),12)
end)
test("wake does not call inactive AutoDim restoration",function()
    local p,a=setup(); a.restoreFrontlight=function() error("unexpected restore") end
    p:onResume(); eq(powerd:frontlightIntensity(),12)
end)
test("AutoDim without a compatible restore method is tolerated",function()
    local p=setup{autodim=false}; ui.autodim={autodim_save_fl=18}
    p:onResume(); eq(powerd:frontlightIntensity(),12)
end)
test("devices without a frontlight still apply night mode",function()
    local p=setup{frontlight=false,warmth=false}; p.schedule[1].night_mode="on"
    p:onResume(); eq(night,true); eq(#writes,0)
end)
test("devices without warmth still apply brightness",function()
    local p=setup{warmth=false}; p:onResume(); eq(powerd:frontlightIntensity(),12)
end)
test("repeated Resume events preserve the scheduled result",function()
    local p,a=setup(); dim_and_suspend(p,a); a:_onResume(); p:onResume(); p:onResume()
    advance(2); eq(powerd:frontlightIntensity(),12)
end)
test("suspend cancels a running scheduled transition",function()
    local p=setup{autodim=false}; p:apply(true); advance(1)
    p:onSuspend(); local current=powerd:frontlightIntensity()
    advance(10); eq(powerd:frontlightIntensity(),current)
    p:onResume(); eq(powerd:frontlightIntensity(),12)
end)
test("manual brightness still interrupts an ordinary smooth transition",function()
    local p=setup{autodim=false}; p:apply(true); advance(1)
    powerd:setIntensity(7); p:onInputEvent(); advance(10)
    eq(powerd:frontlightIntensity(),7)
end)
test("ordinary smooth transitions still reach the target",function()
    local p=setup{autodim=false}; p:apply(true); advance(6)
    eq(powerd:frontlightIntensity(),12)
    eq(powerd:toNativeWarmth(powerd:frontlightWarmth()),12)
end)
print(string.format("%d tests, %d failures",count,failures))
if failures>0 then os.exit(1) end
