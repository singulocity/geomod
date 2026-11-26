local GAP, TILE_WIDTH, TILE_HEIGHT = 8, 142, 132
local BACKGROUND = Color(28, 32, 38)
local TILE = Color(39, 45, 53)
local HOVER = Color(52, 61, 72)
local SELECTED = Color(63, 97, 112)
local BORDER = Color(126, 204, 223)
local TEXT = Color(233, 237, 241)
local MUTED = Color(174, 187, 198)
local active, scan
local catalog = {}

local function scanMaterials(validPath)
    local folders, knownFolders = {"materials"}, {materials = true}
    local known = {}
    local folderIndex = 1
    local deadline = coroutine.yield()
    local function checkpoint()
        if SysTime() >= deadline then deadline = coroutine.yield() end
    end
    while folderIndex <= #folders do
        local folder = folders[folderIndex]
        local files, subfolders = file.Find(folder .. "/*", "GAME")
        checkpoint()
        local prefix = folder == "materials" and "" or folder:sub(11):lower() .. "/"
        for _, fileName in ipairs(files or {}) do
            local lowerName = fileName:lower()
            if lowerName:sub(-4) == ".vmt" then
                local path = validPath(prefix .. lowerName:sub(1, -5))
                if path and not known[path] then
                    known[path] = true
                    catalog[#catalog + 1] = path
                end
            end
            checkpoint()
        end
        for _, child in ipairs(subfolders or {}) do
            local path = folder .. "/" .. child
            local key = path:lower()
            if child ~= "." and child ~= ".." and validPath(key:sub(11)) and not knownFolders[key] then
                knownFolders[key] = true
                folders[#folders + 1] = path
            end
            checkpoint()
        end
        folderIndex = folderIndex + 1
    end
end

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

    if not scan then
        scan = coroutine.create(scanMaterials)
        assert(coroutine.resume(scan, validPath))
    end
    local results = {}
    local visibleTiles, freeTiles, previews = {}, {}, {}
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
    local previewFrame = -1
    local function paintTile(tile, w, h)
        local path = tile.Path
        if path == selected then
            draw.RoundedBox(4, 0, 0, w, h, BORDER)
            draw.RoundedBox(3, 2, 2, w - 4, h - 4, SELECTED)
        else
            draw.RoundedBox(4, 0, 0, w, h, tile:IsHovered() and HOVER or TILE)
        end
        local preview = previews[path]
        if preview == nil and FrameNumber() ~= previewFrame then
            previewFrame = FrameNumber()
            local material = previewMaterial(path)
            preview = material and {
                material = material,
                width = math.max(1, material:Width()),
                height = math.max(1, material:Height()),
            } or false
            previews[path] = preview
        end
        if preview then
            local scale = math.min((w - 14) / preview.width, 86 / preview.height)
            local iw, ih = preview.width * scale, preview.height * scale
            surface.SetMaterial(preview.material)
            surface.SetDrawColor(255, 255, 255)
            surface.DrawTexturedRect((w - iw) / 2, 6 + (86 - ih) / 2, iw, ih)
        elseif preview == false then
            draw.SimpleText("No preview", "DermaDefault", w / 2, 49, MUTED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        draw.SimpleText(tile.Caption, "DermaDefaultBold", w / 2, 98, TEXT, TEXT_ALIGN_CENTER)
        draw.SimpleText(tile.Folder, "DermaDefault", w / 2, 114, MUTED, TEXT_ALIGN_CENTER)
    end

    local function updateTiles()
        local scroll = math.floor(scrollbar:GetScroll())
        local height = canvas:GetTall()
        local first = math.floor(scroll / rowStep) * columns + 1
        local last = math.min(#results, math.ceil((scroll + height - GAP) / rowStep) * columns)
        local nextTiles = {}
        for i = first, last do
            local path = results[i]
            nextTiles[path] = visibleTiles[path] or false
        end
        for path, tile in pairs(visibleTiles) do
            if nextTiles[path] == nil then
                tile:SetVisible(false)
                freeTiles[#freeTiles + 1] = tile
            end
        end
        for i = first, last do
            local path = results[i]
            local tile = nextTiles[path] or table.remove(freeTiles)
            if not tile then
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
            end
            if tile.Path ~= path or tile:GetWide() ~= tileWidth then
                tile.Path = path
                tile.Caption = fitText(string.GetFileFromFilename(path), "DermaDefaultBold", tileWidth - 12)
                tile.Folder = fitText(string.GetPathFromFilename(path), "DermaDefault", tileWidth - 12)
                tile:SetTooltip(path)
                tile:SetSize(tileWidth, TILE_HEIGHT)
            end
            local row, col = math.floor((i - 1) / columns), (i - 1) % columns
            tile:SetPos(GAP + col * (tileWidth + GAP), GAP + row * rowStep - scroll)
            if not tile:IsVisible() then tile:SetVisible(true) end
            nextTiles[path] = tile
        end
        visibleTiles = nextTiles
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

    local terms, cursor, filterAt = {}, 1, 0
    local nextRefresh, shownCount, shownWorking = 0, -1, nil
    local applySingle = false
    local function refresh(working)
        status:SetText(string.format(working and "%d found so far" or "%d materials", #results))
        empty:SetText(working and "Searching materials..." or
            (#catalog == 0 and "No mounted materials found" or "No materials match the filter"))
        empty:SetVisible(#results == 0)
        shownCount, shownWorking = #results, working
        view:InvalidateLayout(true)
    end

    search.OnValueChange = function()
        applySingle = false
        filterAt = RealTime() + .12
    end
    clear.DoClick = function()
        search:SetText("")
        search:RequestFocus()
        applySingle = false
        filterAt = 0
    end
    search.OnEnter = function()
        applySingle = true
        if filterAt then filterAt = 0 end
    end

    function view:Think()
        local now = RealTime()
        if coroutine.status(scan) ~= "dead" then
            assert(coroutine.resume(scan, SysTime() + .0015))
        end
        if filterAt then
            if now < filterAt then return end
            filterAt = nil
            terms, cursor = queryTerms(search:GetValue()), 1
            results = {}
            scrollbar:SetScroll(0)
            shownCount = -1
            nextRefresh = 0
        end
        if #terms == 0 then
            results, cursor = catalog, #catalog + 1
        else
            local deadline = SysTime() + .0005
            local last = math.min(#catalog, cursor + 1023)
            while cursor <= last do
                local path = catalog[cursor]
                local match = true
                for _, term in ipairs(terms) do
                    if not path:find(term, 1, true) then match = false break end
                end
                if match then results[#results + 1] = path end
                cursor = cursor + 1
                if cursor % 64 == 0 and SysTime() >= deadline then break end
            end
        end
        local working = coroutine.status(scan) ~= "dead" or cursor <= #catalog
        if now >= nextRefresh and (shownCount ~= #results or shownWorking ~= working) then
            nextRefresh = now + .12
            refresh(working)
        end
        if applySingle and not working then
            applySingle = false
            if #results == 1 then
                selectPath(results[1])
                use:DoClick()
            end
        end
    end

    search:RequestFocus()
    return frame
end
