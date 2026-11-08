local LrView = import "LrView"
local LrColor = import "LrColor"
local bind = LrView.bind
local Layout = {}
Layout.colors = {
    stage=LrColor(38/255,38/255,38/255), rail=LrColor(.20,.20,.20), strip=LrColor(.15,.15,.15),
    text=LrColor(.93,.93,.93), secondary=LrColor(.76,.76,.76),
}

-- Use fixed SDK dimensions for the lifetime of a dialog. The smaller presets
-- leave room for Windows UI scaling and for the host's window borders.
function Layout.size(hostWidth, hostHeight)
    local pw, ph, rail = 420, 264, 310
    if hostWidth >= 1700 and hostHeight >= 920 then
        pw, ph, rail = 832, 468, 320
    elseif hostWidth >= 1220 and hostHeight >= 700 then
        pw, ph, rail = 640, 384, 320
    end
    local width = pw + 12 + rail
    local slots = math.max(5, math.min(10, math.floor((width - 78) / 101)))
    return { previewWidth=pw, previewHeight=ph, railWidth=rail, width=width,
        stripSlots=slots, thumbnailWidth=math.floor((width-78) / slots)-8 }
end

function Layout.build(f, p, size, actions, parts)
    local width, height = size.previewWidth, size.previewHeight
    local rail = size.railWidth
    local colors = Layout.colors
    local bodyWidth = rail - 40 -- scrollbar and control margins
    local function sectionTitle(title)
        return f:static_text {title=title,font="<system/bold>",text_color=colors.text}
    end
    local function labeled(title, control)
        return f:row { spacing=5, f:static_text {title=title,width=46,text_color=colors.secondary}, control }
    end
    local function picker(title, key, items, enabled)
        return labeled(title, f:popup_menu {value=bind(key),items=items,enabled=bind(enabled),width=bodyWidth-56})
    end
    local function adjust(title,key,low,high,enabled)
        return f:row {spacing=5,
            f:static_text {title=title,width=66,text_color=colors.secondary},
            f:slider {value=bind(key),min=low,max=high,width=bodyWidth-131,enabled=bind(enabled)},
            f:edit_field {value=bind(key),min=low,max=high,precision=2,width=48,enabled=bind(enabled)},
        }
    end
    local stock = f:column {
        spacing=3, sectionTitle("胶片模拟"),
        picker("类型","category",parts.categories,"canRefresh"),
        picker("胶片","film",bind "filmItems","canRefresh"),
        picker("相纸","paper",bind "paperItems","canPaper"),
        picker("工艺","directScan",{{title="相纸印相",value=false},{title="胶片直扫",value=true}},"canScan"),
        f:static_text {title=bind "stockHint",width=bodyWidth,text_color=colors.secondary,truncation="tail"},
    }
    local adjustments = f:column {
        spacing=3,sectionTitle("冲印调整"),
        adjust("胶片曝光 EV","quickFilmEv",-4,4,"canRefresh"),
        adjust("印相亮度 EV","quickPrintEv",-3,3,"canPaper"),
        adjust("颗粒强度","quickGrain",0,2,"canGrain"),
        f:push_button {title="胶片与冲印参数…",enabled=bind "canRefresh",action=actions.edit},
        parts.clipboard,
    }
    local output = f:column {
        spacing=3,sectionTitle("导出设置"),
        picker("模式","mode",{{title="完整模拟",value="full"},
            {title="快速色彩（无颗粒和光晕）",value="fast-color"}},"canEdit"),
        picker("格式","format",{{title="JPEG",value="jpg"},{title="TIFF",value="tif"},
            {title="PNG",value="png"},{title="Cineon DI",value="di"}},"canEdit"),
        labeled("长边", f:row {
            f:edit_field {value=bind "edge",enabled=bind "canEdit",precision=0,min=0,max=65535,width=60},
            f:static_text {title="px（0 原始尺寸）",text_color=colors.secondary},
        }),
        f:row {
            f:push_button {title="选择目录…",action=actions.folder,enabled=bind "canEdit"},
            f:static_text {title=bind "folder",width=bodyWidth-90,truncation="middle",text_color=colors.secondary},
        },
        parts.printing,
    }
    local preview = f:column {
        spacing=4,
        f:row {
            f:static_text {title=bind "photoName",width=width-153,font="<system/bold>",truncation="middle",text_color=colors.text},
            f:static_text {title=bind "selection",width=137,alignment="right",text_color=colors.secondary},
        },
        f:picture {value=bind "canvasPath",width=width,height=height},
        f:row {
            f:push_button {title="上一张",enabled=bind "canPrevious",action=actions.previous},
            f:static_text {title=bind "position",width=68,alignment="center",text_color=colors.secondary},
            f:push_button {title="下一张",enabled=bind "canNext",action=actions.next},
            f:spacer {fill_horizontal=1},
            f:push_button {title="刷新预览",enabled=bind "canRefresh",action=actions.refresh},
        },
    }
    local stageHeight = height+70
    local stage = f:scrolled_view {
        width=width+2,height=stageHeight,horizontal_scroller=false,vertical_scroller=false,
        background_color=colors.stage,preview,
    }
    local controls = f:scrolled_view {
        width=rail,height=stageHeight,horizontal_scroller=false,vertical_scroller=true,background_color=colors.rail,
        f:column {spacing=6,margin=5,stock,f:separator {fill_horizontal=1},adjustments,f:separator {fill_horizontal=1},output},
    }
    return f:view {
        bind_to_object=p, place="vertical", spacing=6,
        f:row {spacing=10,stage,controls},
        f:scrolled_view {width=size.width,height=88,horizontal_scroller=false,vertical_scroller=false,
            background_color=colors.strip,parts.filmstrip},
        f:scrolled_view {width=size.width,height=48,horizontal_scroller=false,vertical_scroller=false,
            background_color=colors.strip,
            f:row {spacing=4,margin=3,
                parts.inspector,
                f:static_text {title=bind "status",width=size.width-478,height_in_lines=2,text_color=colors.secondary},
                f:push_button {title="导出记录",action=actions.history},
                f:push_button {title="完成本项后停止",enabled=bind "canStop",action=actions.stop},
                f:push_button {title=bind "exportTitle",enabled=bind "canExport",action=actions.export},
            },
        },
    }
end

return Layout
