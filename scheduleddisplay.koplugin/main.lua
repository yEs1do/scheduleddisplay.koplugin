local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local _ = require("scheduleddisplay_gettext")
local T = require("ffi/util").template
local Updater = require("scheduleddisplay_updater")
local time = require("ui/time")
local logger = require("logger")

local Powerd = Device:getPowerDevice()
local FILE = DataStorage:getSettingsDir() .. "/scheduleddisplay.lua"
local UNCHANGED = "unchanged"
local MAX = 24
local STEP = 5
local RAMP_MIN, RAMP_MAX, RAMP_STEP = 5, 60, 5
local RAMP_INTERVAL = 0.05
local VERSION = "0.2.1"
local AUTHOR = "yEs1do"

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + .5) end
local function now() local t=os.date("*t"); return t.hour*60+t.min end
local function clock(m) return string.format("%02d:%02d", math.floor(m/60),m%60) end
local function norm(v,max) return round(clamp(v,0,max)/max*100) end
local function native(v,max) if v==UNCHANGED or v==nil then return nil end return round(clamp(v,0,100)/100*max) end
local function hasWarmth() return Device:hasNaturalLight() end
local function hasNight() return Device.screen and type(Device.screen.toggleNightMode)=="function" end
local function sort(s) table.sort(s,function(a,b)return a.time<b.time end) end
local function find(s,t) for i,e in ipairs(s) do if e.time==t then return i end end end
local function effective(s,t)
    if #s==0 then return {} end
    local i=#s
    for n=#s,1,-1 do if s[n].time<=t then i=n;break end end
    local r={}; for off=0,#s-1 do
        local e=s[((i-1-off)%#s)+1]
        if r.brightness==nil and e.brightness~=UNCHANGED then r.brightness=e.brightness end
        if r.warmth==nil and e.warmth~=UNCHANGED then r.warmth=e.warmth end
        if r.night_mode==nil and e.night_mode~=UNCHANGED then r.night_mode=e.night_mode end
    end
    return r
end

local ScheduledDisplay = WidgetContainer:extend{name="scheduleddisplay",is_doc_only=false}

function ScheduledDisplay:init()
    self.settings=LuaSettings:open(FILE)
    self.enabled=self.settings:readSetting("enabled") or false
    self.schedule=self.settings:readSetting("schedule")
    self.smooth=self.settings:readSetting("smooth"); if self.smooth==nil then self.smooth=true end
    self.duration=self.settings:readSetting("smooth_duration") or 5
    self.notify=self.settings:readSetting("notify") or false
    if type(self.schedule)~="table" or #self.schedule==0 then self.schedule=self:defaultSchedule() end
    sort(self.schedule); self:save()
    self.ui.menu:registerToMainMenu(self)
    UIManager.event_hook:registerWidget("InputEvent",self)
    self:reschedule()
end

function ScheduledDisplay:defaultSchedule()
    local fl=Powerd.fl_max or 24; local w=Powerd.fl_warmth_max or 24
    return {
        {time=420,brightness=norm(18,fl),warmth=hasWarmth() and norm(6,w) or UNCHANGED,night_mode="off"},
        {time=1080,brightness=norm(12,fl),warmth=hasWarmth() and norm(18,w) or UNCHANGED,night_mode=UNCHANGED},
        {time=1380,brightness=norm(6,fl),warmth=UNCHANGED,night_mode="on"},
    }
end
function ScheduledDisplay:save()
    self.settings:saveSetting("enabled",self.enabled); self.settings:saveSetting("schedule",self.schedule)
    self.settings:saveSetting("smooth",self.smooth); self.settings:saveSetting("smooth_duration",self.duration)
    self.settings:saveSetting("notify",self.notify); self.settings:flush()
end
function ScheduledDisplay:cancelRamp()
    if self.ramp then UIManager:unschedule(self.ramp) end
    self.ramp=nil
    self.ramp_applying=false
    self.ramp_last_b=nil
    self.ramp_last_w=nil
    self.expected_b=nil
    self.expected_w=nil
    self.ramp_token=(self.ramp_token or 0)+1
end
function ScheduledDisplay:apply(allow_smooth, on_resume)
    local s=effective(self.schedule,now()); local tb=Device:hasFrontlight() and native(s.brightness,Powerd.fl_max) or nil
    local tw=hasWarmth() and native(s.warmth,Powerd.fl_warmth_max) or nil
    if not self.enabled and allow_smooth then return end
    self:cancelRamp()
    if on_resume and tb~=nil then
        -- AutoDim may still own the pre-dim brightness when Resume is broadcast.
        -- Its delayed callback (or input-trap dismissal) would restore that stale
        -- value after our correction. Finish its restore before applying ours;
        -- this also clears its saved value, so later manual changes survive.
        -- Leave AutoDim alone when this schedule does not manage brightness.
        local autodim=self.ui and self.ui.autodim
        if autodim and autodim.autodim_save_fl~=nil
                and type(autodim.restoreFrontlight)=="function" then
            logger.dbg("ScheduledDisplay: completing pending AutoDim restore before wake correction")
            autodim:restoreFrontlight()
        end
    end
    if hasNight() and s.night_mode~=nil and s.night_mode~=UNCHANGED then self.ui:handleEvent(Event:new("SetNightMode",s.night_mode=="on")) end
    local cb=Device:hasFrontlight() and Powerd:frontlightIntensity() or nil
    local cw=hasWarmth() and Powerd:toNativeWarmth(Powerd:frontlightWarmth()) or nil
    local nb=tb~=nil and cb~=tb; local nw=tw~=nil and cw~=tw
    if not nb and not nw then return end
    if not allow_smooth or not self.smooth then
        if nb then Powerd:setIntensity(tb,true) end
        if nw then Powerd:setWarmth(Powerd:fromNativeWarmth(tw)) end
        return
    end
    local from_b,to_b=cb,tb
    local from_w,to_w=cw,tw
    local duration_s=math.max(0.1,tonumber(self.duration) or RAMP_MIN)
    local token=(self.ramp_token or 0)+1
    self.ramp_token=token
    local start=time.now()
    self.ramp_last_b=cb
    self.ramp_last_w=cw
    self.ramp=function()
        if token~=self.ramp_token or not self.enabled then return end
        local elapsed=time.to_s(time.now()-start)
        local p=clamp(elapsed/duration_s,0,1)
        local e=.5-.5*math.cos(math.pi*p)

        self.ramp_applying=true
        if nb then
            local v=round(from_b+(to_b-from_b)*e)
            if v~=self.ramp_last_b then
                self.ramp_last_b=v
                Powerd:setIntensity(v,true)
            end
        end
        if nw then
            local v=round(from_w+(to_w-from_w)*e)
            if v~=self.ramp_last_w then
                self.ramp_last_w=v
                Powerd:setWarmth(Powerd:fromNativeWarmth(v))
            end
        end
        self.ramp_applying=false

        if p>=1 then
            self.ramp_applying=true
            if nb then
                Powerd:setIntensity(to_b,true)
                self.ramp_last_b=to_b
            end
            if nw then
                Powerd:setWarmth(Powerd:fromNativeWarmth(to_w))
                self.ramp_last_w=to_w
            end
            self.ramp_applying=false
            self.ramp=nil
            self.ramp_last_b=nil
            self.ramp_last_w=nil
        else
            UIManager:scheduleIn(RAMP_INTERVAL,self.ramp,self)
        end
    end
    logger.dbg("ScheduledDisplay: smooth ramp",from_b,to_b,from_w,to_w,duration_s)
    self.ramp()
end
function ScheduledDisplay:reschedule()
    if self.task then UIManager:unschedule(self.task);self.task=nil end
    if not self.enabled or #self.schedule==0 then return end
    local n=now(); local next_t=nil
    for _,e in ipairs(self.schedule) do if e.time>n then next_t=e.time;break end end
    if not next_t then next_t=self.schedule[1].time end
    local d=next_t-n;if d<=0 then d=d+1440 end
    self.task=function() self.task=nil;self:apply(true);if self.notify then UIManager:show(InfoMessage:new{text=_("自动显示调节：已应用当前时间点。"),timeout=2}) end;self:reschedule() end
    UIManager:scheduleIn(d*60-os.date("*t").sec,self.task,self)
end
function ScheduledDisplay:_summary(e)
    local b = e.brightness == UNCHANGED and _("不调整") or tostring(native(e.brightness, Powerd.fl_max))
    local w
    if hasWarmth() then
        w = e.warmth == UNCHANGED and _("不调整") or tostring(native(e.warmth, Powerd.fl_warmth_max))
    else
        w = _("不可用")
    end
    local n
    if hasNight() then
        n = e.night_mode == UNCHANGED and _("不调整") or (e.night_mode == "on" and _("开") or _("关"))
    else
        n = _("不可用")
    end
    return T(_("亮度%1·色温%2·反色%3"), b, w, n)
end

function ScheduledDisplay:_buildScheduleItems()
    local items={{
        text=_("添加时间点"),
        enabled_func=function() return #self.schedule<MAX end,
        callback=function(touchmenu_instance) self:_add(touchmenu_instance) end,
        separator=true,
    }}
    for _,e in ipairs(self.schedule) do
        local entry=e
        table.insert(items,{
            text_func=function() return clock(entry.time).."  "..self:_summary(entry) end,
            sub_item_table_func=function()
                return self:_buildEditItems(entry)
            end,
            hold_callback=function(touchmenu_instance)
                self:_delete(entry,touchmenu_instance)
            end,
        })
    end
    return items
end

function ScheduledDisplay:_buildEditItems(e)
    local items={{
        text_func=function() return T(_("时间：%1"),clock(e.time)) end,
        callback=function(touchmenu_instance)
            local old_time=e.time
            self:_time(old_time,function(t)
                local old_i=find(self.schedule,old_time)
                local new_i=find(self.schedule,t)
                if new_i and new_i~=old_i then
                    UIManager:show(InfoMessage:new{text=_("该时间点已存在。"),timeout=2})
                    return
                end
                e.time=t
                sort(self.schedule)
                self:save()
                self:reschedule()
                if touchmenu_instance then
                    if touchmenu_instance.item_table_stack and #touchmenu_instance.item_table_stack > 0 then
                        touchmenu_instance.item_table_stack[#touchmenu_instance.item_table_stack] = self:_buildScheduleItems()
                    end
                    touchmenu_instance:updateItems()
                end
            end,touchmenu_instance)
        end,
        keep_menu_open=true,
    }}
    if Device:hasFrontlight() then
        table.insert(items,{
            text_func=function()
                return T(_("前光亮度：%1"),e.brightness==UNCHANGED and _("不调整") or native(e.brightness,Powerd.fl_max))
            end,
            callback=function(touchmenu_instance)
                self:_number(e,"brightness",Powerd.fl_max,touchmenu_instance)
            end,
            keep_menu_open=true,
        })
    end
    if hasWarmth() then
        table.insert(items,{
            text_func=function()
                return T(_("色温：%1"),e.warmth==UNCHANGED and _("不调整") or native(e.warmth,Powerd.fl_warmth_max))
            end,
            callback=function(touchmenu_instance)
                self:_number(e,"warmth",Powerd.fl_warmth_max,touchmenu_instance)
            end,
            keep_menu_open=true,
        })
    end
    if hasNight() then
        table.insert(items,{
            text_func=function()
                local v=e.night_mode==UNCHANGED and _("不调整") or e.night_mode=="on" and _("开启") or _("关闭")
                return T(_("夜间模式（反色）：%1"),v)
            end,
            callback=function(touchmenu_instance)
                self:_night(e,touchmenu_instance)
            end,
            keep_menu_open=true,
        })
    end
    return items
end

function ScheduledDisplay:_time(initial,cb,parent_menu,parent_schedule_menu)
    local h=math.floor(initial/60);local m=initial%60
    UIManager:show(SpinWidget:new{
        title_text=_("小时"),
        value=h,value_min=0,value_max=23,value_step=1,
        value_hold_step=1,wrap=true,ok_always_enabled=true,
        callback=function(a)
            UIManager:show(SpinWidget:new{
                title_text=_("分钟"),
                value=m,value_min=0,value_max=55,value_step=5,
                value_hold_step=5,wrap=true,ok_always_enabled=true,
                callback=function(b)
                    cb(a.value*60+b.value)
                    if parent_menu then parent_menu:updateItems() end
                    if parent_schedule_menu and parent_schedule_menu~=parent_menu then parent_schedule_menu:updateItems() end
                end,
            })
        end,
    })
end


function ScheduledDisplay:_number(e,key,max,parent_menu)
    local cur=e[key]==UNCHANGED and (key=="brightness" and Powerd:frontlightIntensity() or Powerd:toNativeWarmth(Powerd:frontlightWarmth())) or native(e[key],max)
    UIManager:show(SpinWidget:new{
        title_text=key=="brightness" and _("前光亮度") or _("色温"),
        value=cur or 0,value_min=0,value_max=max,value_step=1,
        extra_text=_("不调整"),
        extra_callback=function()
            e[key]=UNCHANGED
            self:save()
            if parent_menu then parent_menu:updateItems() end
        end,
        callback=function(s)
            e[key]=norm(s.value,max)
            self:save()
            if parent_menu then parent_menu:updateItems() end
        end,
    })
end


function ScheduledDisplay:_night(e,parent_menu)
    UIManager:show(RadioButtonWidget:new{
        title_text=_("夜间模式（反色）"),
        radio_buttons={
            {{text=_("不调整"),provider=UNCHANGED,checked=e.night_mode==UNCHANGED}},
            {{text=_("开启"),provider="on",checked=e.night_mode=="on"}},
            {{text=_("关闭"),provider="off",checked=e.night_mode=="off"}},
        },
        callback=function(w)
            e.night_mode=w.provider
            self:save()
            if parent_menu then parent_menu:updateItems() end
        end,
    })
end


function ScheduledDisplay:_delete(e,parent_menu)
    UIManager:show(ConfirmBox:new{
        text=T(_("确定删除 %1 的自动显示设置吗？"),clock(e.time)),
        ok_text=_("删除"),cancel_text=_("取消"),
        ok_callback=function()
            for i,x in ipairs(self.schedule) do
                if x==e then table.remove(self.schedule,i);break end
            end
            if #self.schedule==0 then
                self.enabled=false
                self:cancelRamp()
            end
            self:save()
            self:reschedule()
            if parent_menu then
                parent_menu.item_table=self:_buildScheduleItems()
                parent_menu:updateItems()
            end
        end,
    })
end


function ScheduledDisplay:_add(parent_menu)
    if #self.schedule>=MAX then
        UIManager:show(InfoMessage:new{text=T(_("最多只能设置 %1 个时间点。"),MAX),timeout=2})
        return
    end
    self:_time(now()-now()%STEP,function(t)
        local i=find(self.schedule,t)
        if i then
            if parent_menu then
                parent_menu.item_table=self:_buildScheduleItems()
                parent_menu:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text=T(_("该时间点已存在：%1。请在时间表中点击该时间点进行编辑。"),clock(t)),
                timeout=4,
            })
            return
        end
        local e={time=t,brightness=UNCHANGED,warmth=UNCHANGED,night_mode=UNCHANGED}
        table.insert(self.schedule,e)
        sort(self.schedule)
        self:save()
        if self.enabled then self:reschedule() end
        if parent_menu then
            parent_menu.item_table=self:_buildScheduleItems()
            parent_menu:updateItems()
        end
        UIManager:show(InfoMessage:new{
            text=T(_("已添加 %1。三个参数默认均为“不调整”，可在时间表中点击该时间点进行设置。"),clock(t)),
            timeout=4,
        })
    end,parent_menu)
end


function ScheduledDisplay:_setEnabled(v,parent)
    self.enabled=v;self:save();if v then self:apply(true);self:reschedule()else self:cancelRamp();if self.task then UIManager:unschedule(self.task);self.task=nil end end;if parent then parent:updateItems()end
end
function ScheduledDisplay:hasAutoWarmthConflict()
    if not G_reader_settings then return false end
    local active=G_reader_settings:readSetting("autowarmth_activate") or 0
    if active==0 then return false end
    return G_reader_settings:nilOrTrue("autowarmth_control_warmth") or G_reader_settings:nilOrTrue("autowarmth_control_nightmode") or G_reader_settings:isTrue("autowarmth_fl_off_during_day")
end
function ScheduledDisplay:_buildAboutItems()
    return {
        {
            text = T(_("当前版本：%1"), VERSION),
        },
        {
            text = T(_("作者：%1"), AUTHOR),
        },
        {
            text = _("手动检查更新"),
            callback = function()
                Updater.check(VERSION)
            end,
        },
    }
end

function ScheduledDisplay:getMenu()
    local m={{
        text_func=function() return self.enabled and _("自动调节：已启用") or _("自动调节：已停用") end,
        checked_func=function() return self.enabled end,
        callback=function(touchmenu_instance) self:_setEnabled(not self.enabled,touchmenu_instance) end,
        keep_menu_open=true,
    },{
        text=_("时间表"),
        enabled_func=function() return #self.schedule>0 end,
        sub_item_table_func=function()
            return self:_buildScheduleItems()
        end,
    },{
        text=_("立即切换"),
        enabled_func=function() return self.enabled and #self.schedule>0 end,
        callback=function() self:apply(true) end,
        keep_menu_open=true,
    },{
        text_func=function() return self.smooth and _("亮度与色温变化：平滑") or _("亮度与色温变化：立即") end,
        checked_func=function() return self.smooth end,
        callback=function(touchmenu_instance)
            self.smooth=not self.smooth
            self:save()
            self:reschedule()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        keep_menu_open=true,
    },{
        text_func=function() return T(_("变化时间：%1 秒"),self.duration) end,
        enabled_func=function() return self.smooth end,
        callback=function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text=_("平滑变化时间"),
                value=self.duration,
                value_min=RAMP_MIN,value_max=RAMP_MAX,value_step=RAMP_STEP,
                value_hold_step=RAMP_STEP,
                default_value=5,
                default_text=_("5 秒"),
                callback=function(s)
                    self.duration=s.value
                    self:save()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
        keep_menu_open=true,
    },{
        text_func=function() return self.notify and _("自动切换提示：已开启") or _("自动切换提示：已关闭") end,
        checked_func=function() return self.notify end,
        callback=function(touchmenu_instance)
            self.notify=not self.notify
            self:save()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        keep_menu_open=true,
    },{
        text=_("关于"),
        sub_item_table_func=function()
            return self:_buildAboutItems()
        end,
    }}
    if self:hasAutoWarmthConflict() then
        table.insert(m,1,{
            text=_("提示：AutoWarmth 可能正在控制显示参数"),
            callback=function()
                UIManager:show(InfoMessage:new{text=_("检测到 AutoWarmth 已启用。自动显示调节不会关闭或修改它，请避免两个时间表同时控制同一参数。"),timeout=4})
            end,
            keep_menu_open=true,
        })
    end
    return m
end


function ScheduledDisplay:addToMainMenu(items)
    items.scheduleddisplay={
        text=_("自动显示调节"),
        sorting_hint="screen",
        checked_func=function() return self.enabled end,
        sub_item_table=self:getMenu(),
    }
end


function ScheduledDisplay:onInputEvent()
    if not self.ramp or self.ramp_applying then return end
    local b=Device:hasFrontlight()
        and self.ramp_last_b~=nil
        and Powerd:frontlightIntensity()~=self.ramp_last_b
    local w=hasWarmth()
        and self.ramp_last_w~=nil
        and Powerd:toNativeWarmth(Powerd:frontlightWarmth())~=self.ramp_last_w
    if b or w then
        logger.dbg("ScheduledDisplay: manual light change detected, cancelling ramp")
        self:cancelRamp()
    end
end
function ScheduledDisplay:onSuspend()self:cancelRamp();if self.task then UIManager:unschedule(self.task);self.task=nil end end
function ScheduledDisplay:onResume()if self.enabled then self:apply(false,true);self:reschedule()end end
function ScheduledDisplay:onCloseWidget()self:onSuspend()end
return ScheduledDisplay
