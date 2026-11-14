#!/usr/bin/env python3
# scripts/pz_pack_web.py
#
# Generate a READY-TO-UPLOAD Steam Workshop item for a pack's "connector" mod.
#
# The connector is deliberately small and non-destructive:
#   * `loadModAfter=` every Mod ID in the pack, so it loads last and a future
#     pack-wide patch file can override the mods it targets;
#   * a generated manifest of the pack's Mod IDs;
#   * a server-start audit that logs which pack mods are missing / extra;
#   * a client prompt that names missing mods and opens their Workshop page,
#     with a button to enable the ones that are installed but switched off.
#
# It does NOT copy, modify or redistribute any other mod's files. That is what
# makes it publishable: the Workshop item is our own code and data only. A
# patch that overwrites another mod's relative path is a separate, deliberate
# change (see docs/plans/pack-web.md), not something this generator does.
#
# The client prompt cannot subscribe or download. `SteamWorkshop.SubscribeItem`
# is not Lua-exposed; only the in-game server-join flow can do that. The prompt
# therefore opens the item page (`activateSteamOverlayToWorkshopItem`) and lets
# Steam do the rest, which is exactly what vanilla's MissedModsWindow does.
#
# The output follows the in-game uploader's layout (verified against
# ~/Zomboid/Workshop/ModTemplate and an installed B42 item):
#
#   <out-dir>/
#     workshop.txt
#     preview.png
#     Contents/mods/<mod-id>/42/mod.info
#     Contents/mods/<mod-id>/42/media/lua/shared/PZPackWeb/manifest.lua
#     Contents/mods/<mod-id>/42/media/lua/shared/PZPackWeb/workshop.lua
#     Contents/mods/<mod-id>/42/media/lua/shared/PZPackWeb/state.lua
#     Contents/mods/<mod-id>/42/media/lua/server/PZPackWeb/audit.lua
#     Contents/mods/<mod-id>/42/media/lua/client/PZPackWeb/prompt.lua
#
# Then: Main Menu -> Workshop -> Create/Update, select the folder, set the
# visibility, Upload. `--workshop-id` updates an existing item.
import argparse
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pz_client_mods as pcm  # noqa: E402

# Reuse the doctor's "which Mod IDs does this Workshop item provide" scanner.
# It is the one implementation of the B42 mod-root / version-folder rules, and
# it is what turns an installed tree into the mod -> Workshop id map the client
# prompt needs. Importing is safe: its CLI is behind main().
import pz_pack_doctor as doctor  # noqa: E402

CATALOGUE_ENV = pcm.CATALOGUE_ENV
WORKSHOP_ENV = doctor.WORKSHOP_ENV
STEAM_APP_ID = "108600"
DEFAULT_WORKSHOP_DIR = os.path.join(os.path.expanduser("~"), "Zomboid", "Workshop")

# The uploader validates the preview: 512x512 max, 8-bit.
PREVIEW_SIZE = 512
VALID_VISIBILITY = ("public", "friendsOnly", "private", "unlisted")

# Only the generated mod id is validated this strictly. Pack Mod IDs may contain
# spaces (real ones do), so they are only checked for characters that would
# break the Lua string literal or the .info line.
_SAFE_GENERATED_ID = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_UNSAFE_VALUE = re.compile(r"[\r\n\"\\]")


def generated_id(pack):
    """`viewpoint` -> `PZPackWebViewpoint`; stable and a Lua identifier."""
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", pack) if p]
    if not parts:
        raise SystemExit(f"pz-pack-web: cannot derive a mod id from pack name {pack!r}")
    return "PZPackWeb" + "".join(p[:1].upper() + p[1:] for p in parts)


def check_value(kind, value):
    """A value that goes into mod.info or a Lua string must be one line."""
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"pz-pack-web: empty {kind}")
    if _UNSAFE_VALUE.search(value):
        raise SystemExit(f"pz-pack-web: {kind} contains a quote, backslash or newline: {value!r}")
    return value


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_preview(path):
    """A valid 512x512 8-bit RGB PNG placeholder.

    The uploader refuses a missing preview and Steam shows this until it is
    replaced. A plain gradient is deliberate: it is obviously a placeholder, and
    it is generated with the stdlib so the app has no image dependency.
    """
    rows = []
    for y in range(PREVIEW_SIZE):
        row = bytearray()
        for x in range(PREVIEW_SIZE):
            # Dark slate with a lighter diagonal band.
            shade = 24 + ((x + y) % 128) // 4
            row += bytes((shade, shade + 8, shade + 16))
        rows.append(b"\x00" + bytes(row))
    raw = zlib.compress(b"".join(rows), 9)
    ihdr = struct.pack(">IIBBBBB", PREVIEW_SIZE, PREVIEW_SIZE, 8, 2, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"IDAT", raw)
    data += png_chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(data)


def copy_preview(source, path):
    """Copy a user preview, rejecting anything the uploader will refuse."""
    with open(source, "rb") as fh:
        head = fh.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise SystemExit(f"pz-pack-web: {source} is not a PNG")
    width, height = struct.unpack(">II", head[16:24])
    if width > PREVIEW_SIZE or height > PREVIEW_SIZE:
        raise SystemExit(
            f"pz-pack-web: {source} is {width}x{height}; the uploader accepts at most "
            f"{PREVIEW_SIZE}x{PREVIEW_SIZE}"
        )
    shutil.copyfile(source, path)


def lua_string(value):
    """A Lua short-string literal. Values were already checked for quotes."""
    return '"' + value + '"'


def default_workshop_root():
    """The first Steam library that has PZ Workshop content, or None.

    The generator runs on a machine that plays the game, not necessarily a
    server, so `--workshop-root` has a sensible default: read
    `libraryfolders.vdf` and pick the first library with
    `steamapps/workshop/content/108600`. This only ever reads.
    """
    home = os.path.expanduser("~")
    steam_roots = [
        os.path.join(home, ".local", "share", "Steam"),
        os.path.join(home, ".steam", "steam"),
    ]
    candidates = list(steam_roots)
    for steam in steam_roots:
        vdf = os.path.join(steam, "steamapps", "libraryfolders.vdf")
        try:
            with open(vdf, encoding="utf-8", errors="replace") as fh:
                candidates.extend(re.findall(r'"path"\s+"([^"]+)"', fh.read()))
        except OSError:
            continue
    for root in candidates:
        workshop = os.path.join(root, "steamapps", "workshop", "content", STEAM_APP_ID)
        if os.path.isdir(workshop):
            return workshop
    return None


def resolve_workshop_ids(pack_data, workshop_root):
    """{Mod ID: Workshop item id} for the pack, from the installed tree.

    The catalogue pairs Workshop ids with titles and lists Mod IDs separately;
    the mapping between the two namespaces only exists inside each installed
    item's `mod.info`. That is why this needs a Workshop root, and why a pack
    generated without one still works — the prompt just cannot link.

    Best effort by design: an item that is not installed is reported, not fatal,
    because the item you are about to publish is by definition not installed
    yet.
    """
    declared = []
    for entry in pack_data.get("workshopMods") or []:
        if isinstance(entry, dict) and str(entry.get("id", "")).isdigit():
            declared.append(str(entry["id"]))
    if not workshop_root or not declared or not os.path.isdir(workshop_root):
        return {}, []

    report = doctor.Report()
    installed, _item_mods = doctor.scan(workshop_root, declared, report)
    return {mod_id: info.item for mod_id, info in installed.items()}, report.errors


# === PART 2 ===

def render_mod_info(pack, mod_id, mods):
    """`42/mod.info` — load last, never require.

    `require=` is a hard dependency: one missing/mature-gated item would make
    PZ skip the connector, which is exactly when the audit is needed. The
    ordering is `loadModAfter`, which is soft and ignored for absent mods.
    """
    order = ",".join(mods)
    return (
        f"name=PZ Pack Web - {pack}\n"
        f"id={mod_id}\n"
        "author=nixos-projectzomboid-servers\n"
        "description=Pack-wide ordering and a start-up audit for this modpack. "
        "Adds no content and overrides no files.\n"
        "versionMin=42.0.0\n"
        f"loadModAfter={order}\n"
    )


def render_manifest(pack, mods, mod_id):
    """Shared Lua table: the authoritative list the audit compares against."""
    lines = [
        "-- Generated by pz-pack-web from the modpack catalogue. Do not edit.",
        "PZPackWeb = PZPackWeb or {}",
        f"PZPackWeb.pack = {lua_string(pack)}",
        f"PZPackWeb.id = {lua_string(mod_id)}",
        f"PZPackWeb.count = {len(mods)}",
        "PZPackWeb.mods = {",
    ]
    lines += [f"    [{lua_string(mod_id)}] = true," for mod_id in mods]
    lines += ["}", ""]
    return "\n".join(lines)


def render_workshop(pack, mods, links):
    """`workshop.lua`: Mod ID -> Workshop item id, for the client prompt.

    Generated from the installed tree rather than the catalogue, because a
    Workshop item and a Mod ID are different namespaces and only `mod.info`
    connects them. A Mod ID with no entry is still listed by the prompt; it just
    has no page to open.
    """
    lines = [
        "-- Generated by pz-pack-web from the installed Workshop tree. Do not edit.",
        "PZPackWeb = PZPackWeb or {}",
        "PZPackWeb.workshop = {",
    ]
    lines += [f"    [{lua_string(mod_id)}] = {lua_string(links[mod_id])}," for mod_id in mods if mod_id in links]
    lines += ["}", ""]
    return "\n".join(lines)


def render_audit():
    """Server-start audit. Read-only, no files, no network, no game state."""
    return r"""-- Generated by pz-pack-web. Read-only: it logs, it changes nothing.
--
-- On a dedicated server, `Mods=` can be missing an entry while the server boots
-- cleanly; PZ only logs a generic "required mod not found" for the entries it
-- tries to load. This compares the ACTIVE list to the generated manifest, so a
-- missing or extra pack mod is named at start.
-- Shared files load before server files for the same mod, so this is normally a
-- no-op; the require is a fallback so a load-order change cannot silently kill
-- the audit. `PZPackWeb/manifest` lives in shared/, hence the require path.
PZPackWeb = PZPackWeb or {}
if not PZPackWeb.mods then
    require "PZPackWeb/manifest"
end
if not PZPackWeb.state then
    require "PZPackWeb/state"
end

local state = PZPackWeb.state

local function summarize(list, limit)
    if #list <= limit then
        return table.concat(list, "; ")
    end
    local shown = {}
    for i = 1, limit do
        shown[i] = list[i]
    end
    return table.concat(shown, "; ") .. string.format("; ... and %d more", #list - limit)
end

local function audit()
    if not isServer or not isServer() then
        return
    end
    if not PZPackWeb.mods then
        return
    end
    local active = state.toSet(getActivatedMods and getActivatedMods() or nil)
    local missing, extra = state.diff(PZPackWeb.mods, active, PZPackWeb.id)

    if #missing == 0 and #extra == 0 then
        print(string.format("[PZPackWeb] %s: all %d pack mods active", PZPackWeb.pack, PZPackWeb.count))
        return
    end
    if #missing > 0 then
        print(string.format(
            "[PZPackWeb] %s: %d pack mod(s) missing: %s",
            PZPackWeb.pack, #missing, summarize(missing, 25)
        ))
    end
    if #extra > 0 then
        print(string.format(
            "[PZPackWeb] %s: %d mod(s) outside the pack: %s",
            PZPackWeb.pack, #extra, summarize(extra, 25)
        ))
    end
end

Events.OnGameStart.Add(audit)
"""


def render_state():
    """Shared pure helpers: no UI, no IO, no game state, so CI can run them."""
    return r"""-- Generated by pz-pack-web. Pure set helpers shared by the audit and the prompt.
--
-- Nothing here draws, reads a file or changes a mod: every function is an
-- operation on the generated manifest, which is what makes it testable in CI.
PZPackWeb = PZPackWeb or {}
PZPackWeb.state = PZPackWeb.state or {}

local state = PZPackWeb.state

-- A java.util.ArrayList (getActivatedMods, ActiveMods:getMods) is 0-based and
-- has :size/:get, not ipairs. Test for the methods, not type(): the Kahlua
-- wrapper is a table, so type(list) == "table" for both shapes.
function state.toSet(list)
    local set = {}
    if not list then
        return set
    end
    if list.size and list.get then
        for i = 0, list:size() - 1 do
            set[list:get(i)] = true
        end
        return set
    end
    for _, id in ipairs(list) do
        set[id] = true
    end
    return set
end

-- Every mod folder the game can see, active or not. getActivatedMods() answers
-- only the active list, so it cannot tell "installed but switched off" from
-- "not installed at all".
function state.installedSet()
    local set = {}
    if not getModDirectoryTable or not getModInfo then
        return set
    end
    for _, directory in ipairs(getModDirectoryTable()) do
        local info = getModInfo(directory)
        local id = info and info:getId() or nil
        if id and id ~= "" then
            set[id] = true
        end
    end
    return set
end

-- Server view: manifest entries that are not active, and active mods the pack
-- does not declare. Sorted so a log line is stable between runs.
function state.diff(manifest, active, selfId)
    local missing, extra = {}, {}
    for id in pairs(manifest) do
        if not active[id] then
            missing[#missing + 1] = id
        end
    end
    for id in pairs(active) do
        -- The connector is active but deliberately not in its own manifest.
        if id ~= selfId and not manifest[id] then
            extra[#extra + 1] = id
        end
    end
    table.sort(missing)
    table.sort(extra)
    return missing, extra
end

-- Client view: mods the player does not have at all, and mods they have but
-- have not enabled. Both leave the pack incomplete; only the first needs a
-- download, so the prompt treats them differently.
function state.classify(manifest, active, installed, selfId)
    local missing, inactive = {}, {}
    for id in pairs(manifest) do
        if id ~= selfId then
            if not installed[id] then
                missing[#missing + 1] = id
            elseif not active[id] then
                inactive[#inactive + 1] = id
            end
        end
    end
    table.sort(missing)
    table.sort(inactive)
    return missing, inactive
end

-- Changes when the incomplete set changes, so the prompt nags once per distinct
-- problem instead of on every launch.
function state.signature(missing, inactive)
    return string.format("%d:%d", #missing, #inactive)
end
"""


def render_prompt():
    """Client-side "you are missing mods" panel.

    It cannot download: `SteamWorkshop.SubscribeItem` is not exposed to Lua, and
    the only automatic download path is the server-join flow that the server's
    own `WorkshopItems=` already drives. So this does what vanilla's
    MissedModsWindow does — open the item page — plus a button that enables mods
    that are installed but switched off.
    """
    return r"""-- Generated by pz-pack-web. Client-only: it draws a panel and, when the player
-- presses a button, either opens a Workshop page or enables installed mods.
--
-- It never downloads and never subscribes. `SteamWorkshop.SubscribeItem` is not
-- exposed to Lua; the game's only automatic download path is the in-game
-- server-join flow. Opening the page and letting Steam ask is the honest limit.
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISModalDialog"

-- Shared files load before client files for the same mod, so this is normally a
-- no-op; the require is a fallback.
PZPackWeb = PZPackWeb or {}
if not PZPackWeb.mods then
    require "PZPackWeb/manifest"
end
if not PZPackWeb.workshop then
    require "PZPackWeb/workshop"
end
if not PZPackWeb.state then
    require "PZPackWeb/state"
end

local state = PZPackWeb.state

local function cfg_name()
    return "pzpackweb_" .. string.gsub(PZPackWeb.pack or "pack", "[^%w_]", "_") .. ".cfg"
end

-- The dismissed-problem signature. Comparing it to the current one means the
-- panel appears when the incomplete set changes, not on every launch.
local function read_signature()
    local ok, line = pcall(function()
        local file = getFileReader(cfg_name(), true)
        if not file then
            return nil
        end
        local value = file:readLine()
        file:close()
        return value
    end)
    if ok then
        return line
    end
    return nil
end

local function write_signature(value)
    pcall(function()
        local file = getFileWriter(cfg_name(), true, false)
        if file then
            file:write(tostring(value) .. "\n")
            file:close()
        end
    end)
end

-- Save the "default" active-mod list with these ids switched on. This is the
-- same pair of calls the mod selector makes when it accepts changes; it has no
-- effect on the current session, hence the restart notice.
local function enable_installed(ids)
    local active = ActiveMods and ActiveMods.getById and ActiveMods.getById("default") or nil
    if not active then
        return 0
    end
    local count = 0
    for _, id in ipairs(ids) do
        active:setModActive(id, true)
        count = count + 1
    end
    if saveModsFile then
        saveModsFile()
    end
    return count
end

PZPackWeb.prompt = ISPanel:derive("PZPackWebPrompt")
local Prompt = PZPackWeb.prompt

function Prompt:new(x, y, width, height, missing, inactive, links)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.missing = missing
    o.inactive = inactive
    o.links = links
    o.backgroundColor = { r = 0.05, g = 0.05, b = 0.05, a = 0.94 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    return o
end

local function row_text(id, installed, linked)
    if installed then
        return id .. "   [installed, not enabled]"
    end
    if linked then
        return id .. "   [missing]"
    end
    return id .. "   [missing, no Workshop link]"
end

function Prompt:createChildren()
    local pad = 12
    local listY = 58
    local listH = self.height - listY - 58

    self.list = ISScrollingListBox:new(pad, listY, self.width - pad * 2, listH)
    self.list:initialise()
    self.list:instantiate()
    self.list:setFont(UIFont.Small)
    self.list.itemheight = math.floor(getTextManager():getFontHeight(UIFont.Small) + 6)
    self.list.drawBorder = true
    for _, id in ipairs(self.missing) do
        self.list:addItem(row_text(id, false, self.links[id] ~= nil), { id = id, installed = false })
    end
    for _, id in ipairs(self.inactive) do
        self.list:addItem(row_text(id, true, self.links[id] ~= nil), { id = id, installed = true })
    end
    if #self.list.items > 0 then
        self.list.selected = 1
    end
    self:addChild(self.list)

    local y = self.height - 44
    self.workshopButton = ISButton:new(pad, y, 190, 30, "Open Workshop page", self, Prompt.onWorkshop)
    self.workshopButton:initialise()
    self.workshopButton:instantiate()
    self.workshopButton:setFont(UIFont.Small)
    self:addChild(self.workshopButton)

    self.enableButton = ISButton:new(pad + 198, y, 210, 30,
        string.format("Enable %d installed", #self.inactive), self, Prompt.onEnable)
    self.enableButton:initialise()
    self.enableButton:instantiate()
    self.enableButton:setFont(UIFont.Small)
    self.enableButton:setEnable(#self.inactive > 0)
    self:addChild(self.enableButton)

    self.copyButton = ISButton:new(pad + 416, y, 110, 30, "Copy list", self, Prompt.onCopy)
    self.copyButton:initialise()
    self.copyButton:instantiate()
    self.copyButton:setFont(UIFont.Small)
    self:addChild(self.copyButton)

    self.closeButton = ISButton:new(self.width - pad - 100, y, 100, 30, "Close", self, Prompt.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self.closeButton:setFont(UIFont.Small)
    self:addChild(self.closeButton)
end

function Prompt:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre("PZ Pack Web - " .. (PZPackWeb.pack or "pack"),
        self.width / 2, 12, 1, 1, 1, 1, UIFont.Large)
    local line = string.format("%d of %d pack mods missing", #self.missing, PZPackWeb.count or 0)
    if #self.inactive > 0 then
        line = line .. string.format(", %d installed but not enabled", #self.inactive)
    end
    self:drawTextCentre(line, self.width / 2, 34, 0.85, 0.85, 0.85, 1, UIFont.Small)
    if self.notice then
        self:drawTextCentre(self.notice, self.width / 2, self.height - 68, 0.6, 0.9, 0.6, 1, UIFont.Small)
    end
end

function Prompt:update()
    ISPanel.update(self)
    local row = self.list.items[self.list.selected]
    local canLink = row ~= nil and self.links[row.item.id] ~= nil
    if self.workshopButton then
        self.workshopButton:setEnable(canLink)
    end
end

function Prompt:onWorkshop()
    local row = self.list.items[self.list.selected]
    if not row then
        return
    end
    local workshop = self.links[row.item.id]
    if workshop and activateSteamOverlayToWorkshopItem then
        activateSteamOverlayToWorkshopItem(workshop)
        return
    end
    self.notice = "No Workshop id for " .. row.item.id
end

function Prompt:onEnable()
    local count = enable_installed(self.inactive)
    write_signature(state.signature(self.missing, {}))
    self:setVisible(false)
    self:removeFromUIManager()
    local text = string.format("Enabled %d mod(s). Restart Project Zomboid to load them.", count)
    local modal = ISModalDialog:new(getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 60, 440, 120, text, false, nil, nil)
    modal:initialise()
    modal:addToUIManager()
end

function Prompt:onCopy()
    if not (Clipboard and Clipboard.setClipboard) then
        return
    end
    local lines = { "Missing from modpack " .. (PZPackWeb.pack or "?") .. ":" }
    for _, id in ipairs(self.missing) do
        local workshop = self.links[id]
        if workshop then
            lines[#lines + 1] = id .. " https://steamcommunity.com/sharedfiles/filedetails/?id=" .. workshop
        else
            lines[#lines + 1] = id
        end
    end
    Clipboard.setClipboard(table.concat(lines, "\n"))
    self.notice = "Copied " .. #self.missing .. " mod(s) to the clipboard"
end

function Prompt:onClose()
    write_signature(state.signature(self.missing, self.inactive))
    self:setVisible(false)
    self:removeFromUIManager()
end

-- The signature already shown this session. OnMainMenuEnter fires again after
-- leaving a game, and a second panel for the same problem is noise.
local shown_signature = nil

local function check()
    if not PZPackWeb.mods or not PZPackWeb.count then
        return
    end
    local active = state.toSet(getActivatedMods and getActivatedMods() or nil)
    local installed = state.installedSet()
    local missing, inactive = state.classify(PZPackWeb.mods, active, installed, PZPackWeb.id)
    if #missing == 0 and #inactive == 0 then
        return
    end
    local sig = state.signature(missing, inactive)
    -- Once per distinct problem per session, and once per dismissal across
    -- launches. OnMainMenuEnter fires again after leaving a game.
    if sig == shown_signature or read_signature() == sig then
        return
    end
    local w = math.min(760, getCore():getScreenWidth() - 80)
    local h = math.min(620, getCore():getScreenHeight() - 80)
    local panel = Prompt:new((getCore():getScreenWidth() - w) / 2,
        (getCore():getScreenHeight() - h) / 2, w, h,
        missing, inactive, PZPackWeb.workshop or {})
    panel:initialise()
    panel:addToUIManager()
    panel:bringToTop()
    shown_signature = sig
end

Events.OnMainMenuEnter.Add(check)
"""


def render_workshop_txt(pack, pack_data, mods, visibility, workshop_id):
    """`workshop.txt`. Repeated `description=` lines, BBCode is allowed."""
    title = f"PZ Pack Web - {pack}"
    description = pack_data.get("description") or f"Pack-wide companion for {pack}."
    lines = [
        "version=1",
    ]
    if workshop_id:
        lines.append(f"id={workshop_id}")
    lines += [
        f"title={title}",
        f"description={description}",
        "description=",
        f"description=Companion mod for the {len(mods)}-mod pack. It declares the pack's "
        "load order and logs any pack mod that is missing (or any extra mod) when a "
        "server starts.",
        "description=",
        "description=On the client it names the pack mods you are missing at the main "
        "menu, opens their Workshop page, and can enable the ones you already have but "
        "have switched off. It cannot download anything for you.",
        "description=",
        "description=It adds no content, overrides no files, and does not redistribute "
        "any other mod. Safe to add to an existing world.",
        "description=",
        "description=Generated from the nixos-projectzomboid-servers modpack catalogue.",
        "tags=Build 42;Multiplayer",
        f"visibility={visibility}",
        "",
    ]
    return "\n".join(lines)


def build_tree(pack, pack_data, target, args, links=None):
    """Write the upload tree into a fresh temp dir, then move it into place."""
    links = links or {}
    mods = [check_value("mod id", m) for m in (pack_data.get("mods") or [])]
    if not mods:
        raise SystemExit(f"pz-pack-web: pack {pack!r} has no mods to link")
    if len(set(mods)) != len(mods):
        raise SystemExit(f"pz-pack-web: pack {pack!r} lists a duplicate Mod ID")

    mod_id = args.mod_id or generated_id(pack)
    if not _SAFE_GENERATED_ID.match(mod_id):
        raise SystemExit(f"pz-pack-web: {mod_id!r} is not a safe generated mod id")

    # Once the connector is added to the pack, the catalogue contains it too.
    # Do not make it depend on or audit itself.
    linked = [m for m in mods if m != mod_id]
    if not linked:
        raise SystemExit(f"pz-pack-web: pack {pack!r} has no mods besides the connector")

    # Only link mods the pack actually loads, and only those the installed tree
    # could resolve. A stray id from an item's other mods is not ours to link.
    emitted = {mod_id_: links[mod_id_] for mod_id_ in linked if mod_id_ in links}

    parent = os.path.dirname(os.path.abspath(target)) or "."
    os.makedirs(parent, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=".pz-pack-web-", dir=parent)
    try:
        item = os.path.join(staging, "item")
        mod_dir = os.path.join(item, "Contents", "mods", mod_id, "42")
        lua_shared = os.path.join(mod_dir, "media", "lua", "shared", "PZPackWeb")
        lua_server = os.path.join(mod_dir, "media", "lua", "server", "PZPackWeb")
        lua_client = os.path.join(mod_dir, "media", "lua", "client", "PZPackWeb")
        os.makedirs(lua_shared)
        os.makedirs(lua_server)
        os.makedirs(lua_client)

        files = {
            os.path.join(mod_dir, "mod.info"): render_mod_info(pack, mod_id, linked),
            os.path.join(lua_shared, "manifest.lua"): render_manifest(pack, linked, mod_id),
            os.path.join(lua_shared, "workshop.lua"): render_workshop(pack, linked, emitted),
            os.path.join(lua_shared, "state.lua"): render_state(),
            os.path.join(lua_server, "audit.lua"): render_audit(),
            os.path.join(lua_client, "prompt.lua"): render_prompt(),
            os.path.join(item, "workshop.txt"): render_workshop_txt(
                pack, pack_data, linked, args.visibility, args.workshop_id
            ),
        }
        for path, text in files.items():
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)

        if args.preview:
            copy_preview(args.preview, os.path.join(item, "preview.png"))
        else:
            write_preview(os.path.join(item, "preview.png"))

        if os.path.lexists(target):
            if not args.force:
                raise SystemExit(
                    f"pz-pack-web: {target} already exists; pass --force to replace it "
                    "(a published item's preview/description edits live there)"
                )
            shutil.rmtree(target)
        os.replace(item, target)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    return mod_id, len(linked), len(emitted)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="pz-pack-web",
        description=(
            "Generate a ready-to-upload Steam Workshop item for a pack's connector mod. "
            "The item declares the pack's load order and audits the active mod list; it "
            "adds no content and overrides no files."
        ),
    )
    parser.add_argument("--pack", required=True, help="Modpack name from the catalogue")
    parser.add_argument(
        "--out-dir",
        default=None,
        help=(
            "Exact Workshop item folder to create. Default: "
            "$HOME/Zomboid/Workshop/PZPackWeb-<pack>"
        ),
    )
    parser.add_argument(
        "--catalogue",
        default=os.environ.get(CATALOGUE_ENV),
        help=f"JSON catalogue (default: ${CATALOGUE_ENV})",
    )
    parser.add_argument(
        "--workshop-root",
        default=os.environ.get(WORKSHOP_ENV) or default_workshop_root(),
        help=(
            "steamapps/workshop/content/108600 root, used to map Mod IDs to "
            f"Workshop ids for the client prompt (default: ${WORKSHOP_ENV}, then the "
            "first Steam library that has PZ Workshop content)"
        ),
    )
    parser.add_argument("--mod-id", default=None, help="Override the generated Mod ID")
    parser.add_argument(
        "--workshop-id",
        default=None,
        help="Existing Workshop id to UPDATE; omit to create a new item",
    )
    parser.add_argument(
        "--visibility",
        choices=VALID_VISIBILITY,
        default="private",
        help="workshop.txt visibility (default: private; change before publishing)",
    )
    parser.add_argument("--preview", default=None, help="Replace the generated 512x512 PNG")
    parser.add_argument("--force", action="store_true", help="Replace an existing --out-dir")
    parser.add_argument("--json", action="store_true", help="Machine-readable summary")
    args = parser.parse_args(argv)

    if args.workshop_id and not args.workshop_id.isdigit():
        parser.error("--workshop-id must be numeric")
    if args.preview and not os.path.isfile(args.preview):
        parser.error(f"--preview {args.preview!r} does not exist")

    if not args.catalogue or not os.path.isfile(args.catalogue):
        print(
            f"pz-pack-web: no readable catalogue at {args.catalogue!r}; "
            "run this through `nix run .#pz-pack-web`",
            file=sys.stderr,
        )
        return 2
    catalogue = pcm.load_catalogue(args.catalogue)
    if catalogue is None:
        return 2
    if args.pack not in catalogue:
        known = ", ".join(sorted(catalogue)) or "(none)"
        print(f"pz-pack-web: no such pack {args.pack!r}; known packs: {known}", file=sys.stderr)
        return 2

    pack_data = catalogue[args.pack]
    target = args.out_dir or os.path.join(DEFAULT_WORKSHOP_DIR, f"PZPackWeb-{args.pack}")
    target = os.path.expanduser(target)

    links, link_errors = resolve_workshop_ids(pack_data, args.workshop_root)
    if args.workshop_root and not os.path.isdir(args.workshop_root):
        print(
            f"pz-pack-web: {args.workshop_root} is not a directory; "
            "the client prompt will have no Workshop links",
            file=sys.stderr,
        )

    mod_id, count, linked_count = build_tree(args.pack, pack_data, target, args, links)

    summary = {
        "pack": args.pack,
        "mod_id": mod_id,
        "mods": count,
        "out_dir": os.path.abspath(target),
        "workshop_id": args.workshop_id,
        "visibility": args.visibility,
        "preview": "provided" if args.preview else "generated placeholder",
        "workshop_root": os.path.abspath(args.workshop_root) if args.workshop_root else None,
        "workshop_links": linked_count,
        "link_errors": link_errors,
    }
    if args.json:
        print(json.dumps(summary, indent=2))
        for message in link_errors[:5]:
            print(f"  note: {message}", file=sys.stderr)
        return 0

    print(f"pz-pack-web: wrote {summary['out_dir']}")
    print(f"  mod id: {mod_id}   linked mods: {count}")
    print(
        f"  workshop.txt: visibility={args.visibility}, "
        + (f"updating id {args.workshop_id}" if args.workshop_id else "new item (no id)")
    )
    if links:
        print(f"  client prompt: {linked_count}/{count} pack mods have a Workshop link")
    else:
        print(
            "  client prompt: no Workshop links "
            "(pass --workshop-root or set $PZ_WORKSHOP_DIR to add them)"
        )
    for message in link_errors[:5]:
        print(f"  note: {message}", file=sys.stderr)
    if not args.preview:
        print("  preview.png is a generated placeholder - replace it with a real 512x512 PNG")
    print()
    print("Next:")
    print("  1. Project Zomboid -> Main Menu -> Workshop -> Create/Update")
    print(f"  2. Select the item folder: {os.path.basename(summary['out_dir'])}")
    print("  3. Review the visibility/description and Upload")
    if not args.workshop_id:
        print(
            f"  4. After upload, add the new Workshop id to the pack's `workshopMods` and "
            f"`{mod_id}` to its `mods` (pz-pack-doctor will verify it)."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

