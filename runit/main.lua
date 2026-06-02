-- micro-run - Press F5 to run the current file, F12 to run make, F9 to make in background
-- Copyright 2020-2022 Tero Karvinen http://TeroKarvinen.com/micro
-- https://github.com/terokarvinen/micro-run

local config = import("micro/config")
local shell = import("micro/shell")
local micro = import("micro")
local os = import("os")

function init()
	config.MakeCommand("runit", runitCommand, config.NoComplete)
	config.TryBindKey("F5", "command:runit", true)

	config.MakeCommand("makeup", makeupCommand, config.NoComplete)
	config.TryBindKey("F12", "command:makeup", true)

	config.MakeCommand("makeupbg", makeupbgCommand, config.NoComplete)
	config.TryBindKey("F9", "command:makeupbg", true)	
end

function find_cargo_root(dir)
	if dir == nil or dir == "" then return nil end
	local f, err = os.Open(dir .. "/Cargo.toml")
	if err == nil then
		f:Close()
		return dir
	end
	local parent = dir:match("^(.*)/[^/]+$")
	if parent == nil or parent == dir then return nil end
	return find_cargo_root(parent)
end

function runitCommand(bp)
	bp:Save()

	local filename = bp.Buf.GetName(bp.Buf)
	local filetype = bp.Buf:FileType()
	local cmd = string.format("./%s", filename)
	if filetype == "go" then
		if string.match(filename, "_test.go$") then
			cmd = "go test"
		else
			cmd = string.format("go run '%s'", filename)
		end
	elseif filetype == "python" then
		cmd = string.format("python3 '%s'", filename)
	elseif filetype == "html" then
		cmd = string.format("firefox-esr '%s'", filename)
	elseif filetype == "lua" then
		cmd = string.format("lua '%s'", filename)
	elseif filetype == "rust" then
		local dir = filename:match("^(.*)/[^/]+$") or "."
		local cargo_dir = find_cargo_root(dir)
		if cargo_dir ~= nil then
			cmd = string.format("sh -c \"cd '%s' && cargo fmt && cargo run\"", cargo_dir)
		else
			cmd = "sh -c \"cargo fmt && cargo run\""
		end
	end

	shell.RunInteractiveShell(cmd, true, false)		
end

function makeJobExit(out, args)
	local out = string.sub(out, -79)
	out = string.gsub(out, "\n", " ")
	micro.InfoBar():Message("'make' done: ...", out)
end

function makeup(bg)
	local err, pwd, prevdir
	for i = 1,20 do
		pwd, err = os.Getwd()
		if err ~= nil then
			micro.InfoBar():Message("Error: os.Getwd() failed!")
			return
		end
		micro.InfoBar():Message("Working directory is ", pwd)

		if pwd == prevdir then
			micro.InfoBar():Message("Makefile not found, looked at ", i, " directories.")
			return
		end
		prevdir = pwd

		local dummy, err = os.Stat("Makefile")
		if err ~= nil then
			micro.InfoBar():Message("(not found in ", pwd, ")")
		else
			if bg then
				micro.InfoBar():Message("Background running make, found Makefile in ", pwd)
				shell.JobStart("cd "..pwd.."; make", nil, nil, makeJobExit, nil)
			else
				micro.InfoBar():Message("Running make, found Makefile in ", pwd)
				local out, err = shell.RunInteractiveShell("make", true, true)
			end
			return
		end

		local err = os.Chdir("..")
		if err ~= nil then
			micro.InfoBar():Message("Error: os.Chdir() failed!")
			return
		end
	end
	micro.InfoBar():Message("Warning: ran full 20 rounds but did not recognize root directory")
	return
end	

function makeupWrapper(bg)
	micro.InfoBar():Message("makeup called")

	local pwd, err = os.Getwd()
	if err ~= nil then
		micro.InfoBar():Message("Error: os.Getwd() failed!")
		return
	end
	micro.InfoBar():Message("Working directory is ", pwd)
	local startDir = pwd

	makeup(bg)

	local err = os.Chdir(startDir)
	if err ~= nil then
		micro.InfoBar():Message("Error: os.Chdir() failed!")
		return
	end
end

function makeupCommand(bp)
	bp:Save()
	makeupWrapper(false)
end

function makeupbgCommand(bp)
	bp:Save()
	makeupWrapper(true)	
end
