--!strict
-- Tern Snapshot: window half (the cx APIs exist only here).
--
-- "Salva configurazione Tern" first saves what has unsaved edits (files through
-- cx.docs:save, notebooks through their native save action), then writes every
-- session of this window, with tabs, split trees and blocks, to
-- <plugin data>\snapshots\AAAA-MM-GG_HHMMSS.json and latest.json, keeping 30.
--
-- The omp conversation of each pane comes from `tern inspect --json`
-- (omp_session_file, per pane); ~/.omp/agent/terminal-sessions is only the
-- fallback, by cwd, and marks the link as uncertain.

local Restore = require("./restore")

local SCHEMA = 1
local KEEP = 30

local VERSION = (function(): string
	local ok, text = pcall(tern.fs.read, "plugin.toml", 64 * 1024)
	return if ok then string.match(text, '\nversion%s*=%s*"([^"]+)"') or "?" else "?"
end)()

local NULL = tern.json.null

local function orNull(v: any): any
	if v == nil or v == "" then
		return NULL
	end
	return v
end

local function join(dir: string, name: string): string
	if string.match(dir, "[\\/]$") then
		return dir .. name
	end
	return dir .. "\\" .. name
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function snapdir(): string
	return join(tern.plugin.data, "snapshots")
end

-- tern.com prints to the console; tern.exe is the GUI binary.
local function ternexe(): string
	local env = tern.getenv("TERN_EXE")
	if env and env ~= "" then
		return env
	end
	local la = tern.getenv("LOCALAPPDATA")
	if la then
		local p = la .. "\\Programs\\Tern\\tern.com"
		if tern.fs.exists(p) then
			return p
		end
	end
	return "tern.com"
end

-- The UUID at the end of an omp session file name (`…_<uuid>.jsonl`).
local function ompid(file: string): string?
	return string.match(file, "_([%x%-]+)%.jsonl$")
end

-- Fallback link: terminal-sessions files whose first line is `cwd`; the
-- newest conversation by the timestamp in its file name wins.
type Candidate = { file: string, count: number }
local function ompcandidate(cwd: string): Candidate?
	local home = tern.getenv("USERPROFILE")
	if not home or cwd == "" then
		return nil
	end
	local dir = home .. "\\.omp\\agent\\terminal-sessions"
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return nil
	end
	local best: string? = nil
	local bestkey = ""
	local seen: { [string]: boolean } = {}
	local count = 0
	local want = string.lower(cwd)
	for _, name in names do
		local rok, text = pcall(tern.fs.read, join(dir, name), 8192)
		if rok then
			local l1, l2 = string.match(text, "^([^\r\n]*)\r?\n([^\r\n]*)")
			if l1 and l2 and string.lower(trim(l1)) == want and ompid(l2) then
				local file = trim(l2)
				if not seen[file] then
					seen[file] = true
					count += 1
				end
				local key = string.match(file, "[\\/](%d%d%d%d%-%d%d%-%d%dT[%d%-]+Z)_") or ""
				if key > bestkey then
					best, bestkey = file, key
				end
			end
		end
	end
	if best then
		return { file = best, count = count }
	end
	return nil
end

-- TabTree -> { pane } | { split, ratio, children = { a, b } }.
local function tree(t: TabTree?): any
	if t == nil then
		return NULL
	end
	if t.pane then
		return { pane = t.pane }
	end
	return {
		split = orNull(t.split),
		ratio = orNull(t.ratio),
		children = tern.json.array({ tree(t[1]), tree(t[2]) }),
	}
end

local function leaves(t: TabTree?, out: { number })
	if t == nil then
		return
	end
	if t.pane then
		table.insert(out, t.pane)
		return
	end
	leaves(t[1], out)
	leaves(t[2], out)
end

local function isomp(info: PaneInfo, file: string?): boolean
	if file then
		return true
	end
	local line = if info.running then info.running.line else ""
	return string.match(line, "^%s*omp[%s%.]") ~= nil or trim(line) == "omp"
		or (info.kind == "agent" and string.find(info.program or "", "omp", 1, true) ~= nil)
end

local function block(cx: WindowCx, info: PaneInfo, ompfiles: { [number]: string }): any
	local kind = info.kind or "terminal"
	local b: { [string]: any } = {
		pane = info.pane,
		kind = kind,
		block = orNull(info.block),
		title = orNull(info.title),
		cwd = orNull(info.cwd),
		program = orNull(info.program),
		running = orNull(if info.running then info.running.line else nil),
		path = NULL,
		url = NULL,
		repo = NULL,
		floating = info.floating == true,
		parked = info.parked == true,
	}
	if kind == "browser" then
		b.url = orNull(info.url)
	elseif kind == "git" then
		b.repo = orNull(info.path)
	else
		b.path = orNull(info.path)
	end
	local file = ompfiles[info.pane]
	if (kind == "terminal" or kind == "agent") and isomp(info, file) then
		if file then
			b.omp = { id = orNull(ompid(file)), file = file, source = "tern", certain = true, note = NULL }
		else
			local c = ompcandidate(info.cwd or "")
			if c then
				b.omp = {
					id = orNull(ompid(c.file)),
					file = c.file,
					source = "terminal-sessions",
					certain = false,
					note = string.format(
						"Dedotto dalla cwd: %d conversazioni con questa cwd, scelta la più recente",
						c.count
					),
				}
			else
				b.omp = {
					id = NULL,
					file = NULL,
					source = NULL,
					certain = false,
					note = "Nessuna conversazione omp trovata per questo blocco",
				}
			end
		end
	end
	return b
end

type Counts = { sessions: number, tabs: number, blocks: number }

local function collect(cx: WindowCx, ompfiles: { [number]: string }): (any, Counts)
	local counts = { sessions = 0, tabs = 0, blocks = 0 }
	local tabinfo: { [number]: TabInfo } = {}
	for _, t in cx.session:tabs() do
		tabinfo[t.id] = t
	end
	local bytab: { [number]: { PaneInfo } } = {}
	local parked = {}
	for _, p in cx.session:panes() do
		if p.tab then
			local list = bytab[p.tab]
			if not list then
				list = {}
				bytab[p.tab] = list
			end
			table.insert(list, p)
		elseif p.parked then
			table.insert(parked, block(cx, p, ompfiles))
			counts.blocks += 1
		end
	end
	local locked: { [number]: boolean } = {}
	for _, s in cx.sessions:list() do
		locked[s.id] = s.locked
	end
	local sessions = {}
	for _, s in cx.session:sessions() do
		counts.sessions += 1
		local tabs = {}
		for i, tid in s.tabs do
			counts.tabs += 1
			local ti = tabinfo[tid]
			local lay = cx.session:layout(tid)
			-- Blocks in tree order, then floats and anything left.
			local order: { number } = {}
			if lay then
				leaves(lay.root, order)
				for _, f in lay.floats do
					table.insert(order, f.pane)
				end
			end
			local byid: { [number]: PaneInfo } = {}
			for _, p in bytab[tid] or {} do
				byid[p.pane] = p
			end
			local blocks = {}
			local done: { [number]: boolean } = {}
			for _, id in order do
				local p = byid[id]
				if p and not done[id] then
					done[id] = true
					table.insert(blocks, block(cx, p, ompfiles))
				end
			end
			for _, p in bytab[tid] or {} do
				if not done[p.pane] then
					table.insert(blocks, block(cx, p, ompfiles))
				end
			end
			counts.blocks += #blocks
			local floats = {}
			if lay then
				for _, f in lay.floats do
					table.insert(floats, { pane = f.pane, over = f.over, corner = f.corner })
				end
			end
			table.insert(tabs, {
				id = tid,
				position = if ti then ti.position else i,
				name = orNull(if ti then ti.name else nil),
				color = orNull(if ti then ti.color else nil),
				zoomed = if lay then lay.zoomed else false,
				focus = orNull(if lay then lay.focus else nil),
				tree = tree(if lay then lay.root else nil),
				floats = tern.json.array(floats),
				blocks = tern.json.array(blocks),
			})
		end
		table.insert(sessions, {
			id = s.id,
			name = s.name,
			locked = if locked[s.id] ~= nil then locked[s.id] else s.locked,
			current = s.current,
			tabs = tern.json.array(tabs),
		})
	end
	return { sessions = tern.json.array(sessions), parked = tern.json.array(parked) }, counts
end

-- Keeps the newest KEEP timestamped snapshots.
local function rotate(dir: string)
	local names = {}
	for _, n in tern.fs.list(dir) do
		if string.match(n, "^%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d%.json$") then
			table.insert(names, n)
		end
	end
	table.sort(names)
	for i = 1, #names - KEEP do
		pcall(tern.fs.remove, join(dir, names[i]))
	end
end

type Saved = { files: { string }, other: { string }, skipped: { string }, errors: { string } }

local busy = false

local function fail(cx: WindowCx, msg: string)
	busy = false
	cx:toast("error", "Snapshot non salvato", msg)
end

-- Step 3: inspect for the omp links, Tern's version, then write.
local function write(cx: WindowCx, saved: Saved, actions: { string })
	local exe = ternexe()
	tern.process.run({ exe, "inspect", "--json" }, { timeout_ms = 15000 }, function(r, cx2)
		local cx = cx2 :: WindowCx
		local ompfiles: { [number]: string } = {}
		local inspectErr: string? = nil
		if r.status == 0 then
			local ok, data = pcall(tern.json.decode, r.stdout)
			if ok and type(data) == "table" and type(data.panes) == "table" then
				for _, p in data.panes do
					if type(p.pane) == "number" and type(p.omp_session_file) == "string" then
						ompfiles[p.pane] = p.omp_session_file
					end
				end
			else
				inspectErr = "tern inspect: JSON non leggibile"
			end
		else
			inspectErr = "tern inspect: uscita " .. r.status .. " " .. trim(r.stderr)
		end
		tern.process.run({ exe, "--version" }, { timeout_ms = 10000 }, function(v, cx3)
			local cx = cx3 :: WindowCx
			local ok, err = pcall(function()
				local snap, counts = collect(cx, ompfiles)
				if inspectErr then
					table.insert(saved.errors, inspectErr .. " (id omp solo da terminal-sessions)")
				end
				local doc = {
					schema = SCHEMA,
					created = os.date("%Y-%m-%dT%H:%M:%S"),
					tern = orNull(string.match(trim(v.stdout), "^tern%s+(.+)$") or trim(v.stdout)),
					plugin = VERSION,
					host = { name = orNull(tern.getenv("COMPUTERNAME")), window = cx:window_key() },
					save_actions = tern.json.array(actions),
					saved = {
						files = tern.json.array(saved.files),
						other = tern.json.array(saved.other),
						skipped = tern.json.array(saved.skipped),
						errors = tern.json.array(saved.errors),
					},
					sessions = snap.sessions,
					parked = snap.parked,
				}
				local text = tern.json.encode(doc, true)
				local dir = snapdir()
				tern.fs.mkdir(dir)
				local path = join(dir, os.date("%Y-%m-%d_%H%M%S") .. ".json")
				tern.fs.write(path, text)
				tern.fs.write(join(dir, "latest.json"), text)
				rotate(dir)
				tern.kv.set("last", {
					at = os.date("%d/%m %H:%M"),
					path = path,
					sessions = counts.sessions,
					tabs = counts.tabs,
					blocks = counts.blocks,
				})
				tern.chrome.refresh()
				local nsaved = #saved.files + #saved.other
				local level: ToastLevel = if #saved.errors > 0 then "info" else "success"
				cx:toast(
					level,
					string.format(
						"Snapshot: %d sessioni, %d schede, %d blocchi, %d salvati%s",
						counts.sessions,
						counts.tabs,
						counts.blocks,
						nsaved,
						if #saved.errors > 0 then string.format(", %d errori", #saved.errors) else ""
					),
					path
				)
			end)
			busy = false
			if not ok then
				cx:toast("error", "Snapshot non salvato", tostring(err))
			end
		end)
	end)
end

-- Step 2: notebooks need focus for their native save action, one at a time,
-- then focus goes back to where it was.
local function savenotebooks(cx: WindowCx, queue: { PaneInfo }, action: string?, saved: Saved, actions: { string }, back: number?)
	if #queue == 0 or action == nil then
		for _, p in queue do
			table.insert(saved.skipped, (p.path or tostring(p.pane)) .. ": nessuna azione di salvataggio per i notebook")
		end
		if back and #queue > 0 then
			pcall(cx.layout.focus, cx.layout, back)
		end
		write(cx, saved, actions)
		return
	end
	local p = table.remove(queue, 1) :: PaneInfo
	local ok, err = pcall(cx.layout.focus, cx.layout, p.pane)
	if not ok then
		table.insert(saved.errors, (p.path or tostring(p.pane)) .. ": " .. tostring(err))
		savenotebooks(cx, queue, action, saved, actions, back)
		return
	end
	tern.timer(150, function(cx2)
		local cx = cx2 :: WindowCx
		local aok, aerr = pcall(cx.actions.run, cx.actions, action :: string)
		if aok then
			table.insert(saved.other, p.path or tostring(p.pane))
		else
			table.insert(saved.errors, (p.path or tostring(p.pane)) .. ": " .. tostring(aerr))
		end
		if #queue == 0 and back then
			pcall(cx.layout.focus, cx.layout, back)
		end
		savenotebooks(cx, queue, action, saved, actions, nil)
	end)
end

-- Step 1: files with unsaved edits, in parallel through cx.docs:save.
local function run(cx: WindowCx)
	if busy then
		cx:toast("info", "Snapshot già in corso")
		return
	end
	busy = true
	local saved: Saved = { files = {}, other = {}, skipped = {}, errors = {} }

	-- Tern 0.9.28 has one generic `save`, run on the focused view.
	local actions: { string } = {}
	local nbaction: string? = nil
	for _, a in cx.actions:list("save") do
		table.insert(actions, a.id)
		if a.id == "save" then
			nbaction = a.id
		end
	end

	local files: { string } = {}
	local notebooks: { PaneInfo } = {}
	for _, p in cx.session:panes() do
		if p.kind == "file" or p.kind == "notebook" or p.kind == "database" then
			local ok, r = pcall(cx.session.read, cx.session, p.pane, { lines = 1, rows = 1, max_chars = 200 })
			local dirty = ok and type(r) == "table" and (r :: any).dirty == true
			if dirty then
				if p.kind == "file" and p.path then
					table.insert(files, p.path)
				elseif p.kind == "notebook" then
					table.insert(notebooks, p)
				else
					table.insert(saved.skipped, (p.path or tostring(p.pane)) .. ": database con modifiche, Tern ha solo 'salva come'")
				end
			end
		end
	end

	local back = cx.session:focused()
	local pending = #files
	if pending == 0 then
		savenotebooks(cx, notebooks, nbaction, saved, actions, back)
		return
	end
	for _, path in files do
		local ok, err = pcall(function()
			cx.docs:save(path):next(function(res, e, cx2)
				if e then
					table.insert(saved.errors, path .. ": " .. e)
				elseif res then
					table.insert(saved.files, path)
				end
				pending -= 1
				if pending == 0 then
					savenotebooks(cx2 :: WindowCx, notebooks, nbaction, saved, actions, back)
				end
			end)
		end)
		if not ok then
			table.insert(saved.errors, path .. ": " .. tostring(err))
			pending -= 1
			if pending == 0 then
				savenotebooks(cx, notebooks, nbaction, saved, actions, back)
			end
		end
	end
end

tern.command({
	id = "save",
	title = "Salva configurazione Tern",
	icon = "save",
	run = function(cx)
		local ok, err = pcall(run, cx)
		if not ok then
			fail(cx, tostring(err))
		end
	end,
})

tern.command({
	id = "restore",
	title = "Ripristina configurazione Tern",
	icon = "save",
	run = function(cx)
		local ok, err = pcall(Restore.run, cx, snapdir())
		if not ok then
			cx:toast("error", "Ripristino non riuscito", tostring(err))
		end
	end,
})

-- Lets Carly restore a snapshot without the pickers (exports take no arguments
-- here): write <plugin data>\restore-request.json = { "path": …, "mode": "skip"|"suffix" },
-- then call restore().
tern.carly.export("restore", {
	sig = "restore()",
	doc = "Ricrea le sessioni dello snapshot indicato in restore-request.json (path, mode skip|suffix) nella cartella dati del plugin; non tocca le sessioni esistenti.",
}, function(...)
	-- The fresh cx is whichever argument has a `toast` method (exports pass
	-- their positional args, then cx and the ExportCall).
	local cx: WindowCx? = nil
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		local ok, has = pcall(function()
			return v.session ~= nil and v.layout ~= nil
		end)
		if ok and has then
			cx = v
			break
		end
	end
	if not cx then
		return "nessun cx ricevuto dall'export"
	end
	local file = join(tern.plugin.data, "restore-request.json")
	local ok, req = pcall(function()
		return tern.json.decode(tern.fs.read(file, 64 * 1024))
	end)
	pcall(tern.fs.remove, file)
	if not ok or type(req) ~= "table" or type(req.path) ~= "string" then
		return "restore-request.json mancante o non valido"
	end
	Restore.restore(cx, req.path, if req.mode == "suffix" then "suffix" else "skip")
	return true
end)

-- The widget: its text shows the last snapshot; its hover card shows what the
-- last snapshot holds and one row of buttons: save, restore the last one,
-- pick another. Card buttons take text only, so their icons are emoji.
-- render runs in a 4 ms budget, so it reads only what the save put in kv.
tern.chrome.widget("save", {
	name = "Tern Snapshot",
	description = "Salva e ripristina sessioni, schede, split e blocchi",
	icon = "save",
	render = function(_pane)
		local last = tern.kv.get("last")
		local at = if type(last) == "table" and type(last.at) == "string" then last.at else nil
		local card: { WidgetCardRow } = {}
		local buttons = { { id = "save", label = "💾 Salva" } }
		if at then
			table.insert(card, { label = "Ultimo", text = at, tone = "accent" })
			if type(last.sessions) == "number" then
				table.insert(card, {
					label = "Contiene",
					text = string.format("%d sessioni · %d schede", last.sessions, last.tabs),
					tone = "muted",
				})
			end
			table.insert(buttons, { id = "restore_last", label = "↩ Ripristina" })
		else
			table.insert(card, { label = "Ultimo", text = "nessuno", tone = "muted" })
		end
		table.insert(buttons, { id = "restore_pick", label = "📂 Scegli" })
		table.insert(card, { id = "actions", text = "", actions = buttons })
		return {
			text = if at then "Snapshot " .. at else "Snapshot",
			card = card,
			command = "plugin.tern-snapshot.save",
		}
	end,
})

tern.on("widget_action", function(ev: WidgetActionEvent, cx: WindowCx)
	if ev.widget ~= "save" then
		return nil
	end
	local ok, err = pcall(function()
		if ev.act == "save" then
			run(cx)
		elseif ev.act == "restore_last" then
			local last = tern.kv.get("last")
			local path = if type(last) == "table" and type(last.path) == "string" then last.path else nil
			if path and tern.fs.exists(path) then
				Restore.ask(cx, path)
			else
				Restore.run(cx, snapdir())
			end
		elseif ev.act == "restore_pick" then
			Restore.run(cx, snapdir())
		end
	end)
	if not ok then
		busy = false
		cx:toast("error", "Tern Snapshot", tostring(err))
	end
	return true
end)
