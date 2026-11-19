--!strict
-- "Ripristina configurazione Tern": rebuilds the sessions of a snapshot.
--
-- Never closes or changes an existing session: a session whose name already
-- exists is skipped or recreated as "<name> (ripristino)", as the user picks.
--
-- Each tab is built with cx.layout:tab from the saved split tree. TabSpec
-- leaves can only run commands or plugin blocks, so a file/git/browser/board/
-- notebook/database leaf starts as a placeholder shell; the native block opens
-- beside it, is swapped into its slot (cx.layout:move "swap") and the
-- placeholder closes. omp agents run `omp --resume <id>` in their cwd.
-- Panes the plugin creates are the only ones it ever closes.

local M = {}

local SUFFIX = " (ripristino)"

local function join(dir: string, name: string): string
	if string.match(dir, "[\\/]$") then
		return dir .. name
	end
	return dir .. "\\" .. name
end

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function home(): string
	return tern.getenv("USERPROFILE") or "C:\\"
end

-- What a leaf runs, and what still has to open in its slot afterwards.
type Native = { kind: string, path: string?, url: string?, repo: string?, title: string }
type Leaf = { launch: Launch, native: Native?, note: string? }

local leafkind: (b: any, cwd: string) -> Leaf

local function leafof(b: any): Leaf
	local cwd = str(b.cwd) or home()
	local gone: string? = nil
	if not tern.fs.exists(cwd) then
		gone = (str(b.title) or cwd) .. ": la cartella `" .. cwd .. "` non esiste più, aperto nella home"
		cwd = home()
	end
	local leaf = leafkind(b, cwd)
	if gone then
		leaf.note = if leaf.note then gone .. "; " .. leaf.note else gone
	end
	return leaf
end

leafkind = function(b: any, cwd: string): Leaf
	local kind = str(b.kind) or "terminal"
	local title = str(b.title) or kind
	if kind == "terminal" or kind == "agent" then
		local omp = b.omp
		if type(omp) == "table" then
			local id = str(omp.id)
			if id then
				local note = if omp.certain == false
					then title .. ": conversazione omp incerta (" .. (str(omp.note) or "dedotta dalla cwd") .. ")"
					else nil
				return { launch = { cwd = cwd, command = "omp --resume " .. id }, note = note }
			end
			return { launch = { cwd = cwd }, note = title .. ": agente omp senza id, aperta una shell" }
		end
		-- Plain shells come back empty: their command is not run again.
		local running = str(b.running)
		return {
			launch = { cwd = cwd },
			note = if running then title .. ": il comando `" .. running .. "` non è stato rilanciato" else nil,
		}
	end
	if kind == "plugin" then
		local blk = str(b.block)
		if blk then
			return { launch = { cwd = cwd, block = blk } }
		end
		return { launch = { cwd = cwd }, note = title .. ": blocco plugin senza tipo, aperta una shell" }
	end
	if kind == "file" or kind == "board" or kind == "notebook" or kind == "database" or kind == "git"
		or kind == "browser" then
		return {
			launch = { cwd = cwd },
			native = { kind = kind, path = str(b.path), url = str(b.url), repo = str(b.repo), title = title },
		}
	end
	return { launch = { cwd = cwd }, note = title .. ": tipo `" .. kind .. "` non ricreabile, aperta una shell" }
end

-- Snapshot tree -> TabSpec; `order` gets the leaves left to right.
local function spec(node: any, byid: { [number]: any }, order: { Leaf }): TabSpec?
	if type(node) ~= "table" then
		return nil
	end
	if type(node.pane) == "number" then
		local b = byid[node.pane]
		if not b then
			return nil
		end
		local leaf = leafof(b)
		table.insert(order, leaf)
		return { launch = leaf.launch }
	end
	local kids = if type(node.children) == "table" then node.children else {}
	local a = spec(kids[1], byid, order)
	local c = spec(kids[2], byid, order)
	if a and c then
		local s: TabSpec = { split = if node.split == "down" then "down" else "right", a, c }
		if type(node.ratio) == "number" then
			s.ratio = node.ratio
		end
		return s
	end
	return a or c
end

local function leavesof(t: TabTree?, out: { number })
	if t == nil then
		return
	end
	if t.pane then
		table.insert(out, t.pane)
		return
	end
	leavesof(t[1], out)
	leavesof(t[2], out)
end

local function tabset(cx: WindowCx, session: number): { [number]: boolean }
	local out = {}
	for _, s in cx.session:sessions() do
		if s.id == session then
			for _, t in s.tabs do
				out[t] = true
			end
		end
	end
	return out
end

local function panesin(cx: WindowCx, tab: number): { [number]: boolean }
	local out = {}
	for _, p in cx.session:panes() do
		if p.tab == tab then
			out[p.pane] = true
		end
	end
	return out
end

type Report = { created: { string }, skipped: { string }, problems: { string }, tabs: number, blocks: number }

-- Opens a native block beside `holder` and puts it in the holder's slot.
-- Returns the new pane, or nil and why.
local function opennative(cx: WindowCx, tab: number, holder: number, n: Native, done: (number?, string?) -> ())
	local before = panesin(cx, tab)
	local function finish()
		local new: number? = nil
		for _, p in cx.session:panes() do
			if p.tab == tab and not before[p.pane] then
				new = p.pane
			end
		end
		if not new then
			done(nil, n.title .. ": il blocco " .. n.kind .. " non si è aperto")
			return
		end
		local moved = cx.layout:move(new, holder, "swap", { focus = false })
		cx.layout:close(holder)
		if moved then
			done(new, nil)
		else
			done(new, n.title .. ": aperto accanto, proporzioni dello split approssimate")
		end
	end
	cx.layout:focus(holder)
	if n.kind == "file" then
		if not n.path then
			done(nil, n.title .. ": file senza percorso")
			return
		end
		if not tern.fs.exists(n.path) then
			done(nil, n.path .. ": il file non esiste più")
			return
		end
		cx.docs:open(n.path, { how = "beside" })
		finish()
	elseif n.kind == "board" then
		if not n.path then
			done(nil, n.title .. ": board senza percorso")
			return
		end
		cx.board:open(n.path, { how = "beside" })
		finish()
	elseif n.kind == "notebook" then
		if not n.path then
			done(nil, n.title .. ": notebook senza percorso")
			return
		end
		cx.notebook:open(n.path)
		finish()
	elseif n.kind == "database" then
		if not n.path then
			done(nil, n.title .. ": database senza percorso")
			return
		end
		cx:open(n.path, "beside")
		finish()
	elseif n.kind == "browser" then
		if not n.url then
			done(nil, n.title .. ": browser senza indirizzo")
			return
		end
		cx:open(n.url, "beside")
		finish()
	elseif n.kind == "git" then
		local repo = n.repo or n.path
		if not repo then
			done(nil, n.title .. ": git senza repository")
			return
		end
		local ok, err = pcall(function()
			cx.git:open(repo, { how = "beside" }):next(function(_pane, e, cx2)
				cx = cx2 :: WindowCx
				if e then
					cx.layout:close(holder)
					done(nil, repo .. ": " .. e)
					return
				end
				finish()
			end)
		end)
		if not ok then
			done(nil, repo .. ": " .. tostring(err))
		end
	end
end

-- Builds one tab; `next` continues once its native blocks have opened.
local function buildtab(cx: WindowCx, session: number, t: any, rep: Report, next: (cx: WindowCx) -> ())
	local byid: { [number]: any } = {}
	for _, b in (if type(t.blocks) == "table" then t.blocks else {}) do
		if type(b.pane) == "number" and not b.floating and not b.parked then
			byid[b.pane] = b
		end
	end
	local order: { Leaf } = {}
	local s = spec(t.tree, byid, order)
	local label = str(t.name) or ("scheda " .. tostring(t.position or "?"))
	if not s then
		table.insert(rep.problems, label .. ": scheda senza blocchi ricreabili")
		next(cx)
		return
	end
	s.name = str(t.name)
	-- A leaf's cwd only reaches the shell through the spec node itself.
	local function cwds(node: TabSpec)
		if node.launch and node.launch.cwd then
			node.cwd = node.launch.cwd
		end
		if node[1] then
			cwds(node[1])
		end
		if node[2] then
			cwds(node[2])
		end
	end
	cwds(s)
	local tid, err = cx.layout:tab(s, { focus = false })
	if not tid then
		table.insert(rep.problems, label .. ": " .. (err or "scheda non creata"))
		next(cx)
		return
	end
	if err then
		table.insert(rep.problems, label .. ": " .. err)
	end
	rep.tabs += 1
	-- New tabs open next to the focused one: put each at the end, in saved order.
	local count = 0
	for _, sinfo in cx.session:sessions() do
		if sinfo.id == session then
			count = #sinfo.tabs
		end
	end
	pcall(cx.layout.order_tab, cx.layout, tid, count)
	if str(t.color) then
		pcall(cx.layout.color_tab, cx.layout, tid, t.color)
	end
	for _, l in order do
		if l.note then
			table.insert(rep.problems, l.note)
		end
	end
	-- Pair each leaf with the pane cx.layout:tab made for it (same left-to-right order).
	local panes: { number } = {}
	local lay = cx.session:layout(tid)
	if lay then
		leavesof(lay.root, panes)
	end
	rep.blocks += #panes
	local jobs: { { holder: number, native: Native } } = {}
	for i, l in order do
		if l.native and panes[i] then
			table.insert(jobs, { holder = panes[i], native = l.native })
		end
	end
	local function step(cx: WindowCx)
		local job = table.remove(jobs, 1)
		if not job then
			next(cx)
			return
		end
		local ok, perr = pcall(opennative, cx, tid, job.holder, job.native, function(_pane, problem)
			if problem then
				table.insert(rep.problems, problem)
			end
			-- Let the window settle before the next open.
			tern.timer(120, function(cx2)
				step(cx2 :: WindowCx)
			end)
		end)
		if not ok then
			table.insert(rep.problems, job.native.title .. ": " .. tostring(perr))
			step(cx)
		end
	end
	step(cx)
end

-- The tab that cx.sessions:create made, closed once real tabs exist; only if
-- it still holds just its own starting shell.
local function dropstarter(cx: WindowCx, session: number, starter: { [number]: boolean })
	for tab in starter do
		local panes = {}
		for p in panesin(cx, tab) do
			table.insert(panes, p)
		end
		if #panes == 1 then
			cx.layout:close(panes[1])
		end
	end
end

local function buildsession(cx: WindowCx, s: any, name: string, rep: Report, next: (cx: WindowCx) -> ())
	local first = if type(s.tabs) == "table" and s.tabs[1] and type(s.tabs[1].blocks) == "table"
			and s.tabs[1].blocks[1]
		then str(s.tabs[1].blocks[1].cwd)
		else nil
	local ok, created = pcall(cx.sessions.create, cx.sessions, { name = name, cwd = first or home() })
	if not ok then
		table.insert(rep.problems, name .. ": sessione non creata (" .. tostring(created) .. ")")
		next(cx)
		return
	end
	local sid = (created :: ManagedSession).id
	local starter = tabset(cx, sid)
	table.insert(rep.created, name)
	local tabs = {}
	for _, t in (if type(s.tabs) == "table" then s.tabs else {}) do
		table.insert(tabs, t)
	end
	table.sort(tabs, function(a, b)
		return (tonumber(a.position) or 0) < (tonumber(b.position) or 0)
	end)
	local function step(cx: WindowCx)
		local t = table.remove(tabs, 1)
		if not t then
			if rep.tabs > 0 then
				dropstarter(cx, sid, starter)
			end
			if s.locked == true then
				pcall(cx.sessions.lock, cx.sessions, sid)
			end
			next(cx)
			return
		end
		-- New tabs open in the current session: keep it the restored one.
		pcall(cx.sessions.switch, cx.sessions, sid)
		buildtab(cx, sid, t, rep, step)
	end
	step(cx)
end

local function summary(cx: WindowCx, rep: Report, path: string)
	local lines = {
		"# Ripristino Tern",
		"",
		"Snapshot: `" .. path .. "`",
		"",
		string.format("- Sessioni ricreate: %d (%s)", #rep.created, table.concat(rep.created, ", ")),
		string.format("- Schede: %d, blocchi: %d", rep.tabs, rep.blocks),
	}
	if #rep.skipped > 0 then
		table.insert(lines, "- Saltate perché esistono già: " .. table.concat(rep.skipped, ", "))
	end
	table.insert(lines, "")
	if #rep.problems == 0 then
		table.insert(lines, "Tutto ricreato.")
	else
		table.insert(lines, string.format("## Non ricreato o diverso (%d)", #rep.problems))
		table.insert(lines, "")
		for _, p in rep.problems do
			table.insert(lines, "- " .. p)
		end
	end
	local text = table.concat(lines, "\n") .. "\n"
	local file = join(join(tern.plugin.data, "restores"), os.date("%Y-%m-%d_%H%M%S") .. ".md")
	pcall(tern.fs.mkdir, join(tern.plugin.data, "restores"))
	pcall(tern.fs.write, file, text)
	cx:toast(
		if #rep.problems > 0 then "info" else "success",
		string.format(
			"Ripristino: %d sessioni, %d schede, %d blocchi%s",
			#rep.created,
			rep.tabs,
			rep.blocks,
			if #rep.problems > 0 then string.format(", %d da controllare", #rep.problems) else ""
		),
		file
	)
	pcall(cx.docs.new_note, cx.docs, "Ripristino Tern", (string.gsub(text, "^# Ripristino Tern\n\n", "")))
end

local function existing(cx: WindowCx): { [string]: boolean }
	local out = {}
	for _, s in cx.sessions:list() do
		out[s.name] = true
	end
	return out
end

local function unique(names: { [string]: boolean }, base: string): string
	local name = base .. SUFFIX
	local n = 2
	while names[name] do
		name = string.format("%s (ripristino %d)", base, n)
		n += 1
	end
	return name
end

local function start(cx: WindowCx, doc: any, path: string, mode: string)
	local rep: Report = { created = {}, skipped = {}, problems = {}, tabs = 0, blocks = 0 }
	local names = existing(cx)
	local back = cx.sessions:current().id
	local queue: { { s: any, name: string } } = {}
	for _, s in (if type(doc.sessions) == "table" then doc.sessions else {}) do
		local base = str(s.name) or "Sessione"
		if names[base] then
			if mode == "suffix" then
				local name = unique(names, base)
				names[name] = true
				table.insert(queue, { s = s, name = name })
			else
				table.insert(rep.skipped, base)
			end
		else
			names[base] = true
			table.insert(queue, { s = s, name = base })
		end
	end
	if type(doc.parked) == "table" and #doc.parked > 0 then
		table.insert(rep.problems, string.format("%d blocchi parcheggiati non ricreati", #doc.parked))
	end
	for _, s in (if type(doc.sessions) == "table" then doc.sessions else {}) do
		for _, t in (if type(s.tabs) == "table" then s.tabs else {}) do
			for _, b in (if type(t.blocks) == "table" then t.blocks else {}) do
				if b.floating or b.parked then
					table.insert(rep.problems, (str(b.title) or "blocco") .. ": era flottante o parcheggiato, non ricreato")
				end
			end
		end
	end
	local function step(cx: WindowCx)
		local item = table.remove(queue, 1)
		if not item then
			pcall(cx.sessions.switch, cx.sessions, back)
			summary(cx, rep, path)
			return
		end
		buildsession(cx, item.s, item.name, rep, step)
	end
	step(cx)
end

local function load(path: string): (any, string?)
	local ok, text = pcall(tern.fs.read, path, 16 * 1024 * 1024)
	if not ok then
		return nil, tostring(text)
	end
	local dok, doc = pcall(tern.json.decode, text)
	if not dok or type(doc) ~= "table" or type(doc.sessions) ~= "table" then
		return nil, "non è uno snapshot leggibile"
	end
	if doc.schema ~= 1 then
		return nil, "schema " .. tostring(doc.schema) .. " non supportato"
	end
	return doc, nil
end

local function count(doc: any): (number, number)
	local tabs, blocks = 0, 0
	for _, s in doc.sessions do
		for _, t in (if type(s.tabs) == "table" then s.tabs else {}) do
			tabs += 1
			blocks += if type(t.blocks) == "table" then #t.blocks else 0
		end
	end
	return tabs, blocks
end

-- Asks which snapshot, then, if names clash, skip or suffix; then restores.
function M.run(cx: WindowCx, dir: string)
	local ok, names = pcall(tern.fs.list, dir)
	if not ok or #names == 0 then
		cx:toast("info", "Nessuno snapshot da ripristinare", dir)
		return
	end
	local items: { PickItem } = {}
	for i = #names, 1, -1 do
		local n = names[i]
		if string.match(n, "%.json$") and n ~= "latest.json" then
			local doc = load(join(dir, n))
			if doc then
				local tabs, blocks = count(doc)
				local list = {}
				for _, s in doc.sessions do
					table.insert(list, tostring(s.name))
				end
				table.insert(items, {
					label = (string.gsub(n, "%.json$", "")),
					detail = string.format("%d sessioni, %d schede, %d blocchi: %s", #doc.sessions, tabs, blocks,
						table.concat(list, ", ")),
					file = join(dir, n),
				})
			end
		end
	end
	if #items == 0 then
		cx:toast("info", "Nessuno snapshot da ripristinare", dir)
		return
	end
	cx:pick({ items = items, placeholder = "Snapshot da ripristinare", icon = "save", action = "ripristina" })
		:next(function(item, _e, cx2)
			local cx = cx2 :: WindowCx
			if not item then
				return
			end
			local path = item.file :: string
			local doc, err = load(path)
			if not doc then
				cx:toast("error", "Snapshot non leggibile", (err or "") .. "\n" .. path)
				return
			end
			local have = existing(cx)
			local clash = {}
			for _, s in doc.sessions do
				if have[tostring(s.name)] then
					table.insert(clash, tostring(s.name))
				end
			end
			if #clash == 0 then
				start(cx, doc, path, "skip")
				return
			end
			cx:pick({
				items = {
					{ label = "Salta le sessioni che esistono già", detail = table.concat(clash, ", "), mode = "skip" },
					{ label = "Creale con il suffisso" .. SUFFIX, detail = table.concat(clash, ", "), mode = "suffix" },
				},
				placeholder = string.format("%d sessioni esistono già: le esistenti non vengono toccate", #clash),
				icon = "save",
				action = "scegli",
			}):next(function(choice, _e2, cx3)
				if choice then
					start(cx3 :: WindowCx, doc, path, choice.mode :: string)
				end
			end)
		end)
end

-- For tests and scripted use: restores `path` with a fixed clash mode.
function M.restore(cx: WindowCx, path: string, mode: string)
	local doc, err = load(path)
	if not doc then
		cx:toast("error", "Snapshot non leggibile", (err or "") .. "\n" .. path)
		return
	end
	start(cx, doc, path, mode)
end

return M
