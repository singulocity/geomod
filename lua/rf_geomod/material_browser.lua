local GAP, TILE_WIDTH, TILE_HEIGHT = 8, 142, 132
local BACKGROUND = Color(28, 32, 38)
local TILE = Color(39, 45, 53)
local HOVER = Color(52, 61, 72)
local SELECTED = Color(63, 97, 112)
local BORDER = Color(126, 204, 223)
local TEXT = Color(233, 237, 241)
local MUTED = Color(174, 187, 198)
local active, catalog

local function fitText(value, font, width)
    surface.SetFont(font)
    if surface.GetTextSize(value) <= width then return value end
    while #value > 0 and surface.GetTextSize(value .. "...") > width do
        value = value:sub(1, -2)
    end
    return value .. "..."
end

local function queryTerms(query)
    local terms = {}
    for word in query:lower():gmatch("%S+") do
        word = word:gsub("^materials/", ""):gsub("%.vmt$", "")
        if word ~= "" then terms[#terms + 1] = word end
    end
    return terms
end

return function(title, current, validPath, previewMaterial, applyMaterial)
    if IsValid(active) then active:Remove() end
    local frame = vgui.Create("DFrame")
    active = frame
    frame:SetName("GeoModMaterialBrowser")
    frame:SetTitle(title)
    frame:SetSize(math.min(1140, ScrW() - 32), math.min(820, ScrH() - 32))
    frame:SetMinWidth(math.min(520, ScrW() - 32))
    frame:SetMinHeight(math.min(380, ScrH() - 32))
    frame:SetSizable(true)
    frame:DockPadding(10, 30, 10, 10)
    frame:Center()
    frame:MakePopup()

    local filterBar = vgui.Create("DPanel", frame)
    filterBar:Dock(TOP)
    filterBar:DockMargin(0, 0, 0, 8)
    filterBar:SetTall(28)
    filterBar:SetPaintBackground(false)
    local clear = vgui.Create("DButton", filterBar)
    clear:Dock(RIGHT)
    clear:SetWide(64)
    clear:SetText("Clear")
    local search = vgui.Create("DTextEntry", filterBar)
    search:SetName("MaterialFilter")
    search:Dock(FILL)
    search:DockMargin(0, 0, 8, 0)
    search:SetPlaceholderText("Filter materials by name or path")
    search:SetUpdateOnType(true)

    local footer = vgui.Create("DPanel", frame)
    footer:Dock(BOTTOM)
    footer:DockMargin(0, 8, 0, 0)
    footer:SetTall(36)
    footer:SetPaintBackground(false)
    local use = vgui.Create("DButton", footer)
    use:Dock(RIGHT)
    use:SetWide(116)
    use:SetText("Use material")
    local status = vgui.Create("DLabel", footer)
    status:SetName("MaterialCount")
    status:Dock(LEFT)
    status:SetWide(130)
    status:SetDark(true)
    status:SetText("Indexing materials...")
    local selection = vgui.Create("DLabel", footer)
    selection:Dock(FILL)
    selection:DockMargin(0, 0, 8, 0)
    selection:SetWrap(true)
    selection:SetDark(true)

    local view = vgui.Create("DPanel", frame)
    view:SetName("MaterialGrid")
    view:Dock(FILL)
    view.Paint = function(_, w, h) draw.RoundedBox(4, 0, 0, w, h, BACKGROUND) end
    local scrollbar = vgui.Create("DVScrollBar", view)
    local canvas = vgui.Create("Panel", view)
    canvas:SetMouseInputEnabled(true)
    local empty = vgui.Create("DLabel", canvas)
    empty:SetContentAlignment(5)
    empty:SetTextColor(MUTED)
    empty:Dock(FILL)
    empty:SetText("Indexing materials...")

    local folders, knownFolders = {"materials"}, {materials = true}
    local paths, known = catalog or {}, {}
    local folderIndex = 1
    local indexed = catalog ~= nil
    local results, tiles = {}, {}
    local selected = validPath(current:lower():gsub("^materials/", ""):gsub("%.vmt$", ""))
    if selected and not file.Exists("materials/" .. selected .. ".vmt", "GAME") then selected = nil end
    local function selectPath(path)
        selected = path
        selection:SetText(path or "")
        selection:SetTooltip(path or "")
        use:SetEnabled(path ~= nil)
    end
    selectPath(selected)

    use.DoClick = function()
        if not selected then return end
        applyMaterial(selected)
        frame:Close()
    end

    local columns, tileWidth = 1, TILE_WIDTH
    local rowStep = TILE_HEIGHT + GAP
    local previewFrame, previews = -1, 0
    local function paintTile(tile, w, h)
        local path = tile.Path
        if path == selected then
            draw.RoundedBox(4, 0, 0, w, h, BORDER)
            draw.RoundedBox(3, 2, 2, w - 4, h - 4, SELECTED)
        else
            draw.RoundedBox(4, 0, 0, w, h, tile:IsHovered() and HOVER or TILE)
        end
        if tile.Preview == nil then
            local number = FrameNumber()
            if number ~= previewFrame then previewFrame, previews = number, 0 end
            if previews < 8 then
                previews = previews + 1
                tile.Preview = previewMaterial(path) or false
                if tile.Preview then
                    local width, height = math.max(1, tile.Preview:Width()), math.max(1, tile.Preview:Height())
                    local scale = math.min((w - 14) / width, 86 / height)
                    tile.ImageWidth, tile.ImageHeight = width * scale, height * scale
                end
            end
        end
        if tile.Preview then
            local iw, ih = tile.ImageWidth, tile.ImageHeight
            surface.SetMaterial(tile.Preview)
            surface.SetDrawColor(255, 255, 255)
            surface.DrawTexturedRect((w - iw) / 2, 6 + (86 - ih) / 2, iw, ih)
        elseif tile.Preview == false then
            draw.SimpleText("No preview", "DermaDefault", w / 2, 49, MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        draw.SimpleText(tile.Caption, "DermaDefaultBold", w / 2, 98, TEXT, TEXT_ALIGN_CENTER)
        draw.SimpleText(tile.Folder, "DermaDefault", w / 2, 114, MUTED, TEXT_ALIGN_CENTER)
    end

    local function updateTiles()
        local scroll = math.floor(scrollbar:GetScroll())
        local height = canvas:GetTall()
        local first = math.floor(scroll / rowStep)
        local rows = math.ceil((height + scroll % rowStep) / rowStep)
        local used = 0
        for row = first, first + rows - 1 do
            for col = 0, columns - 1 do
                local path = results[row * columns + col + 1]
                if path then
                    used = used + 1
                    local tile = tiles[used]
                    if not IsValid(tile) then
                        tile = vgui.Create("DButton", canvas)
                        tile:SetName("MaterialTile")
                        tile:SetText("")
                        tile.Paint = paintTile
                        tile.OnMouseWheeled = function(_, delta) return view:OnMouseWheeled(delta) end
                        tile.DoClick = function(self) selectPath(self.Path) end
                        tile.DoDoubleClick = function(self)
                            selectPath(self.Path)
                            use:DoClick()
                        end
                        tiles[used] = tile
                    end
                    if tile.Path ~= path or tile:GetWide() ~= tileWidth then
                        tile.Path, tile.Preview = path, nil
                        tile.Caption = fitText(string.GetFileFromFilename(path), "DermaDefaultBold", tileWidth - 12)
                        tile.Folder = fitText(string.GetPathFromFilename(path), "DermaDefault", tileWidth - 12)
                        tile:SetTooltip(path)
                    end
                    tile:SetSize(tileWidth, TILE_HEIGHT)
                    tile:SetPos(GAP + col * (tileWidth + GAP), GAP + row * rowStep - scroll)
                    tile:SetVisible(true)
                end
            end
        end
        for i = used + 1, #tiles do tiles[i]:SetVisible(false) end
    end

    function view:PerformLayout(w, h)
        if w < 32 or h < 32 then return end
        local canvasWidth = w - 16
        columns = math.max(1, math.floor((canvasWidth - GAP) / (TILE_WIDTH + GAP)))
        tileWidth = math.floor((canvasWidth - GAP) / columns) - GAP
        canvas:SetSize(canvasWidth, h)
        scrollbar:SetPos(canvasWidth, 0)
        scrollbar:SetSize(16, h)
        scrollbar:SetUp(h, math.ceil(#results / columns) * rowStep + GAP)
        updateTiles()
    end
    function view:OnVScroll() updateTiles() end
    function view:OnMouseWheeled(delta)
        return scrollbar:AddScroll(-delta * rowStep * 2 / 25)
    end
    canvas.OnMouseWheeled = function(_, delta) return view:OnMouseWheeled(delta) end

    local filterAt = indexed and 0
    local function filter(resetScroll)
        local terms = queryTerms(search:GetValue())
        results = {}
        for _, path in ipairs(paths) do
            local match = true
            for _, term in ipairs(terms) do
                if not path:find(term, 1, true) then match = false break end
            end
            if match then results[#results + 1] = path end
        end
        status:SetText(string.format(indexed and "%d materials" or "%d found (scanning)", #results))
        empty:SetText(not indexed and "Indexing materials..." or
            (#paths == 0 and "No mounted materials found" or "No materials match the filter"))
        empty:SetVisible(#results == 0)
        if resetScroll then scrollbar:SetScroll(0) end
        view:InvalidateLayout(true)
    end

    search.OnValueChange = function() filterAt = RealTime() + .12 end
    clear.DoClick = function()
        search:SetText("")
        search:RequestFocus()
        filterAt = 0
    end
    search.OnEnter = function()
        if not indexed then return end
        filterAt = nil
        filter(true)
        if #results == 1 then
            selectPath(results[1])
            use:DoClick()
        end
    end

    local nextScanRefresh = 0
    function view:Think()
        local now = RealTime()
        if not indexed then
            local deadline = SysTime() + .005
            repeat
                local folder = folders[folderIndex]
                local files, subfolders = file.Find(folder .. "/*", "GAME")
                for _, child in ipairs(subfolders or {}) do
                    local path = folder .. "/" .. child
                    local key = path:lower()
                    if child ~= "." and child ~= ".." and validPath(key:sub(11)) and not knownFolders[key] then
                        knownFolders[key] = true
                        folders[#folders + 1] = path
                    end
                end
                for _, fileName in ipairs(files or {}) do
                    if fileName:lower():sub(-4) == ".vmt" then
                        local path = validPath((folder:sub(11) .. "/" .. fileName:sub(1, -5)):gsub("^/", ""):lower())
                        if path and not known[path] then
                            known[path] = true
                            paths[#paths + 1] = path
                        end
                    end
                end
                folderIndex = folderIndex + 1
            until folderIndex > #folders or SysTime() >= deadline
            if folderIndex > #folders then
                indexed = true
                folders, knownFolders, known = nil, nil, nil
                table.sort(paths)
                catalog = paths
                filterAt = 0
            elseif now >= nextScanRefresh and not filterAt then
                nextScanRefresh = now + .3
                filter(false)
            end
        end
        if filterAt and now >= filterAt then
            filterAt = nil
            filter(true)
        end
    end

    search:RequestFocus()
    return frame
end
