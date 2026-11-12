(() => {
  "use strict";

  // Resolve against the page, not the origin: the dashboard is served behind a
  // reverse proxy that strips a prefix (e.g. /pz-admin/ -> /), so an absolute
  // /api/... would point at the proxy root instead of the service.
  const API = new URL("api/", document.baseURI).pathname;

  const state = {
    servers: [],
    meta: {},
    current: null,
    allow: new Set(),
    timer: null,
    tick: 0,
    configLoadedFor: null,
    bannerTimer: null,
    countdownTimer: null,
    nowOffset: 0,
  };

  const $ = (id) => document.getElementById(id);

  // ── fetch helpers ──────────────────────────────────────────────────────

  async function api(path, options = {}) {
    const response = await fetch(API + path, {
      cache: "no-store",
      ...options,
      headers: {
        // The service requires this on mutating requests; a cross-origin form
        // cannot set it without a CORS preflight, which the service refuses.
        "X-PZ-Manage": "1",
        ...(options.headers || {}),
      },
    });
    const text = await response.text();
    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }
    if (!response.ok) {
      throw new Error((data && data.error) || `${response.status} ${response.statusText}`);
    }
    return data;
  }

  async function post(path, body) {
    return api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  }

  // ── formatting ─────────────────────────────────────────────────────────

  function fmtBytes(bytes) {
    if (bytes === null || bytes === undefined) return "—";
    const units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let value = Number(bytes);
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
  }

  function fmtUptime(seconds) {
    if (seconds === null || seconds === undefined) return "—";
    let s = Math.max(0, Math.floor(seconds));
    const d = Math.floor(s / 86400);
    s %= 86400;
    const h = Math.floor(s / 3600);
    s %= 3600;
    const m = Math.floor(s / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    if (m) return `${m}m`;
    return `${s}s`;
  }

  function fmtDate(epochSeconds) {
    if (!epochSeconds) return "—";
    return new Date(epochSeconds * 1000).toLocaleString();
  }

  function fmtWhen(epochSeconds) {
    if (!epochSeconds) return "—";
    return new Date(epochSeconds * 1000).toLocaleString([], {
      weekday: "short",
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  function fmtClock(epochSeconds) {
    if (!epochSeconds) return "—";
    return new Date(epochSeconds * 1000).toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  function fmtCountdown(seconds) {
    if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return "—";
    let s = Math.max(0, Math.round(seconds));
    if (s <= 0) return "now";
    const d = Math.floor(s / 86400);
    s %= 86400;
    const h = Math.floor(s / 3600);
    s %= 3600;
    const m = Math.floor(s / 60);
    s %= 60;
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    if (m) return `${m}m ${s}s`;
    return `${s}s`;
  }

  function fmtValue(value) {
    if (value === true) return "true";
    if (value === false) return "false";
    if (value === null || value === undefined) return "—";
    if (Array.isArray(value)) return value.join(", ");
    if (typeof value === "object") return JSON.stringify(value);
    return String(value);
  }

  // ── DOM helpers ────────────────────────────────────────────────────────

  function el(tag, props = {}, children = []) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (value === null || value === undefined || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key === "dataset") Object.assign(node.dataset, value);
      else if (key.startsWith("on") && typeof value === "function") {
        node.addEventListener(key.slice(2).toLowerCase(), value);
      } else {
        node.setAttribute(key, value === true ? "" : String(value));
      }
    }
    for (const child of [].concat(children)) {
      if (child === null || child === undefined) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function setBanner(message, kind = "ok") {
    const banner = $("banner");
    banner.textContent = message;
    banner.className = `banner ${kind}`;
    if (state.bannerTimer) clearTimeout(state.bannerTimer);
    state.bannerTimer = setTimeout(() => banner.classList.add("hidden"), 6000);
  }

  function reportError(error) {
    setBanner(error.message || String(error), "error");
    console.error(error);
  }

  // ── state ──────────────────────────────────────────────────────────────

  function currentServer() {
    return state.servers.find((server) => server.name === state.current) || null;
  }

  function currentMeta() {
    return state.meta[state.current] || null;
  }

  // ── tabs ───────────────────────────────────────────────────────────────

  function renderTabs() {
    const nav = $("servers");
    clear(nav);
    for (const server of state.servers) {
      const button = el("button", {
        class: "tab",
        type: "button",
        text: server.serverName || server.name,
        title: server.description || server.name,
        "aria-current": server.name === state.current ? "true" : "false",
        onclick: () => selectServer(server.name),
      });
      nav.append(button);
    }
  }

  function selectServer(name) {
    state.current = name;
    state.configLoadedFor = null;
    if (location.hash !== `#${name}`) history.replaceState(null, "", `#${name}`);
    renderTabs();
    refresh({ force: true });
  }

  // ── status ─────────────────────────────────────────────────────────────

  function renderStatus(status) {
    const box = $("status");
    clear(box);
    if (!status) {
      box.append(el("div", { class: "empty", text: "No status available." }));
      return;
    }

    const stateClass = status.active
      ? "active"
      : status.state === "failed"
        ? "failed"
        : "inactive";

    const cards = [
      {
        label: "State",
        value: el("span", {
          class: `badge ${stateClass}`,
          text: status.state || "unknown",
        }),
      },
      { label: "Uptime", value: fmtUptime(status.uptime) },
      { label: "Memory", value: fmtBytes(status.memory) },
      {
        label: "Players",
        value:
          status.players === null || status.players === undefined
            ? "—"
            : `${status.players} / ${status.maxPlayers ?? "?"}`,
      },
      {
        label: "Ports",
        value: `${status.defaultPort ?? "—"} / ${status.udpPort ?? "—"} udp`,
      },
      {
        label: "RCON",
        value: status.rcon ? `${status.rconPort} tcp` : "off",
      },
      {
        label: "Console",
        value: status.console
          ? el("a", { href: status.console, text: "open" })
          : "—",
      },
    ];

    for (const card of cards) {
      box.append(
        el("div", { class: "card" }, [
          el("div", { class: "label", text: card.label }),
          el("div", { class: "value" }, [card.value]),
        ]),
      );
    }

    if (status.rconError) {
      box.append(
        el("div", { class: "card" }, [
          el("div", { class: "label", text: "RCON note" }),
          el("div", { class: "value small", text: status.rconError }),
        ]),
      );
    }
  }

  // ── schedule / countdowns ──────────────────────────────────────────────

  function countdownEl(target, prefix = "") {
    if (!target) return el("span", { class: "muted", text: "—" });
    return el("span", {
      class: "countdown",
      dataset: { countdown: String(target), prefix },
    });
  }

  function tickCountdowns() {
    const now = Date.now() / 1000 + state.nowOffset;
    for (const node of document.querySelectorAll("[data-countdown]")) {
      const target = Number(node.dataset.countdown);
      if (!Number.isFinite(target)) continue;
      node.textContent = `${node.dataset.prefix || ""}${fmtCountdown(target - now)}`;
    }
  }

  function renderSchedule(status) {
    const box = $("schedule");
    clear(box);
    if (!status) {
      box.append(el("div", { class: "empty", text: "No schedule data." }));
      return;
    }

    const schedule = status.schedule || {};
    const starts = schedule.start || [];
    const nextStart = schedule.nextStart;
    const idle = status.idleStop || {};

    const startValue = el("div", { class: "value compact" });
    if (starts.length) {
      startValue.append(el("div", { text: starts.join(" · ") }));
      if (nextStart) {
        startValue.append(
          el("div", { class: "muted small" }, [
            "next ",
            el("span", { text: fmtWhen(nextStart) }),
            " (",
            countdownEl(nextStart, ""),
            ")",
          ]),
        );
      } else {
        startValue.append(
          el("div", {
            class: "muted small",
            text: "timer is active but has no next elapse",
          }),
        );
      }
    } else {
      startValue.append(el("span", { class: "muted", text: "No scheduled start" }));
    }

    const idleValue = el("div", { class: "value compact" });
    if (!idle.enabled) {
      idleValue.append(el("span", { class: "muted", text: "Disabled" }));
    } else {
      idleValue.append(
        el("div", { text: `Stop after ${idle.timeout || "?"} with no players` }),
      );
      if (!status.active) {
        idleValue.append(el("div", { class: "muted small", text: "server is stopped" }));
      } else if (status.players !== null && status.players !== undefined && status.players > 0) {
        idleValue.append(
          el("div", {
            class: "muted small",
            text: `${status.players} player(s) online — idle timer reset`,
          }),
        );
      } else if (!status.rcon) {
        idleValue.append(
          el("div", {
            class: "muted small",
            text: "RCON unavailable — idle timer paused",
          }),
        );
      } else if (idle.stopAt) {
        idleValue.append(
          el("div", { class: "muted small" }, [
            "empty since ",
            el("span", { text: fmtClock(idle.emptySince) }),
            " — stops in ",
            countdownEl(idle.stopAt, ""),
          ]),
        );
      } else {
        idleValue.append(
          el("div", {
            class: "muted small",
            text: "empty; idle timer starts within a minute",
          }),
        );
      }
    }

    box.append(
      el("div", { class: "card" }, [
        el("div", { class: "label", text: "Scheduled start" }),
        startValue,
      ]),
      el("div", { class: "card" }, [
        el("div", { class: "label", text: "Idle shutdown" }),
        idleValue,
      ]),
    );
    tickCountdowns();
  }

  // ── actions ────────────────────────────────────────────────────────────

  async function doAction(verb, arg) {
    try {
      const result = await post("action", { server: state.current, verb, arg });
      setBanner(`${verb}: ${result.ok ? "ok" : "failed"}${result.output ? ` — ${result.output}` : ""}`, result.ok ? "ok" : "error");
      await refresh({ force: true });
    } catch (error) {
      reportError(error);
    }
  }

  function actionButton(label, verb, { danger = false, disabled = false, arg } = {}) {
    return el("button", {
      type: "button",
      class: danger ? "danger" : "",
      text: label,
      disabled: disabled || !state.allow.has(verb),
      onclick: () => {
        if (verb === "broadcast") {
          const message = window.prompt("Broadcast message to the server:");
          if (message) doAction("broadcast", message);
          return;
        }
        if ((verb === "stop" || verb === "restart") && !window.confirm(`${label} the server?`)) {
          return;
        }
        doAction(verb, arg);
      },
    });
  }

  function renderActions(status) {
    const box = $("actions");
    clear(box);
    if (!status) return;
    const active = Boolean(status.active);
    const rcon = Boolean(status.rcon);

    box.append(
      actionButton("Save", "save", { disabled: !active || !rcon }),
      actionButton("Broadcast", "broadcast", { disabled: !active || !rcon }),
      actionButton("Restart", "restart", { disabled: !active, danger: true }),
      actionButton("Stop", "stop", { disabled: !active, danger: true }),
      actionButton("Start", "start", { disabled: active }),
    );
  }

  // ── players ────────────────────────────────────────────────────────────

  function renderPlayers(players) {
    const box = $("players");
    const count = $("player-count");
    clear(box);

    if (!players) {
      count.textContent = "";
      box.append(el("div", { class: "empty", text: "No player data." }));
      return;
    }

    count.textContent = players.rcon ? `${players.count} connected` : "";

    if (!players.online) {
      box.append(el("div", { class: "empty", text: "The server is stopped." }));
      return;
    }
    if (!players.rcon) {
      box.append(
        el("div", {
          class: "empty",
          text: players.error || "RCON is unavailable, so the player list cannot be read.",
        }),
      );
      return;
    }
    if (!players.players.length) {
      box.append(el("div", { class: "empty", text: "No players connected." }));
      return;
    }

    if (players.ambiguous) {
      box.append(
        el("div", {
          class: "empty",
          text: "The players reply is ambiguous (a username contains a newline). Per-player actions are disabled.",
        }),
      );
    }

    const table = el("table");
    table.append(
      el("thead", {}, [
        el("tr", {}, [
          el("th", { text: "Player" }),
          el("th", { class: "right", text: "Actions" }),
        ]),
      ]),
    );
    const body = el("tbody");
    for (const name of players.players) {
      const actions = el("div", { class: "row-actions" }, [
        el("button", {
          type: "button",
          text: "Kick",
          disabled: players.ambiguous || !state.allow.has("kick"),
          onclick: () => doAction("kick", name),
        }),
        el("button", {
          type: "button",
          class: "danger",
          text: "Ban",
          disabled: players.ambiguous || !state.allow.has("ban"),
          onclick: () => {
            if (window.confirm(`Ban ${name}?`)) doAction("ban", name);
          },
        }),
      ]);
      body.append(
        el("tr", {}, [
          el("td", {}, [el("code", { text: name })]),
          el("td", { class: "right" }, [actions]),
        ]),
      );
    }
    table.append(body);
    box.append(table);
  }

  // ── logs ───────────────────────────────────────────────────────────────

  function renderLogs(logs) {
    const pre = $("logs");
    if (!logs) {
      pre.textContent = "No log data.";
      return;
    }
    const heading = $("logs-heading");
    heading.querySelector(".muted")?.remove();
    if (logs.file) {
      heading.append(el("span", { class: "muted small", text: ` ${logs.file}` }));
    }
    const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 24;
    pre.textContent = logs.error
      ? `error: ${logs.error}`
      : logs.lines.length
        ? logs.lines.join("\n")
        : "No log lines yet — the server writes its log once it has started.";
    if (atBottom) pre.scrollTop = pre.scrollHeight;
  }

  // ── config ─────────────────────────────────────────────────────────────

  function renderKeyValues(object) {
    const list = el("dl", { class: "kv" });
    const keys = Object.keys(object || {}).sort();
    if (!keys.length) {
      return el("div", { class: "empty", text: "No values." });
    }
    for (const key of keys) {
      list.append(
        el("dt", { text: key }),
        el("dd", {}, [el("code", { text: fmtValue(object[key]) })]),
      );
    }
    return list;
  }

  function renderTags(values, emptyText) {
    if (!values || !values.length) {
      return el("div", { class: "empty", text: emptyText });
    }
    const box = el("div", { class: "tags" });
    for (const value of values) box.append(el("span", { class: "tag", text: value }));
    return box;
  }

  function renderConfig(config) {
    const box = $("config");
    clear(box);
    if (!config) {
      box.append(el("div", { class: "empty", text: "No config data." }));
      return;
    }
    $("config-note").textContent = config.note || "";

    const summary = el("div", { class: "kv" }, [
      el("dt", { text: "Modpack" }),
      el("dd", { text: config.modpack || "(none)" }),
      el("dt", { text: "Map" }),
      el("dd", { text: config.map || "(auto-detected from installed mods)" }),
      el("dt", { text: "Ports" }),
      el("dd", { text: `${config.defaultPort} / ${config.udpPort} udp, ${config.rconPort} rcon` }),
      el("dt", { text: "Max players" }),
      el("dd", { text: String(config.maxPlayers) }),
      el("dt", { text: "Public" }),
      el("dd", { text: fmtValue(config.public) }),
    ]);
    box.append(el("details", { open: true }, [el("summary", { text: "Effective values" }), summary]));
    box.append(
      el("details", {}, [el("summary", { text: `Settings (${Object.keys(config.settings || {}).length})` }), renderKeyValues(config.settings)]),
    );
    box.append(
      el("details", {}, [el("summary", { text: `SandboxVars (${Object.keys(config.sandbox || {}).length})` }), renderKeyValues(config.sandbox)]),
    );
    box.append(
      el("details", {}, [el("summary", { text: `Mods (${(config.mods || []).length})` }), renderTags(config.mods, "No mods.")]),
    );
    box.append(
      el("details", {}, [el("summary", { text: `Workshop items (${(config.workshopItems || []).length})` }), renderTags(config.workshopItems, "No Workshop items.")]),
    );
  }

  // ── backups ────────────────────────────────────────────────────────────

  async function renderBackups() {
    const box = $("backups");
    const meta = currentMeta();
    if (!meta) return;
    $("backup-dir").textContent = meta.backupDirectory || "";
    try {
      const entries = await api(`backups?server=${encodeURIComponent(state.current)}`);
      clear(box);
      if (!entries.length) {
        box.append(el("div", { class: "empty", text: "No backups yet." }));
        return;
      }
      const table = el("table");
      table.append(
        el("thead", {}, [
          el("tr", {}, [
            el("th", { text: "Archive" }),
            el("th", { text: "Size" }),
            el("th", { text: "Created" }),
            el("th", { class: "right", text: "Actions" }),
          ]),
        ]),
      );
      const body = el("tbody");
      for (const entry of entries) {
        const url = `${API}backups/download?server=${encodeURIComponent(state.current)}&name=${encodeURIComponent(entry.name)}`;
        body.append(
          el("tr", {}, [
            el("td", {}, [el("code", { text: entry.name })]),
            el("td", { text: fmtBytes(entry.size) }),
            el("td", { text: fmtDate(entry.mtime) }),
            el("td", { class: "right" }, [
              el("div", { class: "row-actions" }, [
                el("a", { href: url, text: "Download" }),
                el("button", {
                  type: "button",
                  class: "danger",
                  text: "Delete",
                  onclick: async () => {
                    if (!window.confirm(`Delete ${entry.name}?`)) return;
                    try {
                      await api(
                        `backups?server=${encodeURIComponent(state.current)}&name=${encodeURIComponent(entry.name)}`,
                        { method: "DELETE" },
                      );
                      setBanner(`Deleted ${entry.name}`, "ok");
                      await renderBackups();
                    } catch (error) {
                      reportError(error);
                    }
                  },
                }),
              ]),
            ]),
          ]),
        );
      }
      table.append(body);
      box.append(table);
    } catch (error) {
      clear(box);
      box.append(el("div", { class: "empty", text: error.message }));
    }
  }

  // ── refresh loop ───────────────────────────────────────────────────────

  async function refresh({ force = false } = {}) {
    if (!state.current) return;
    if (document.visibilityState === "hidden" && !force) return;
    const name = state.current;
    try {
      const [statuses, players, logs] = await Promise.all([
        api("status"),
        api(`players?server=${encodeURIComponent(name)}`),
        api(`logs?server=${encodeURIComponent(name)}&lines=400`),
      ]);
      const status = statuses.find((entry) => entry.name === name) || null;
      state.meta[name] = { ...(state.meta[name] || {}), ...status };
      state.nowOffset = status && status.now ? status.now - Date.now() / 1000 : 0;
      renderStatus(status);
      renderSchedule(status);
      renderActions(status);
      renderPlayers(players);
      renderLogs(logs);

      if (state.configLoadedFor !== name) {
        renderConfig(await api(`config?server=${encodeURIComponent(name)}`));
        state.configLoadedFor = name;
      }

      state.tick += 1;
      if (state.tick % 6 === 0) await renderBackups();

      $("updated").textContent = `updated ${new Date().toLocaleTimeString()}`;
    } catch (error) {
      reportError(error);
    }
  }

  function schedule() {
    if (state.timer) clearInterval(state.timer);
    const seconds = Math.max(2, Number(state.meta.refreshSeconds) || 5);
    state.timer = setInterval(() => refresh(), seconds * 1000);
  }

  async function boot() {
    try {
      const payload = await api("servers");
      state.servers = payload.servers || [];
      state.meta = { ...payload, servers: undefined };
      state.allow = new Set(payload.allowActions || []);
      $("title").textContent = payload.title || "Project Zomboid";
      document.title = payload.title || "Project Zomboid";

      if (!state.servers.length) {
        $("status").append(el("div", { class: "empty", text: "No servers are enabled." }));
        return;
      }

      const fromHash = location.hash.replace(/^#/, "");
      state.current = state.servers.some((server) => server.name === fromHash)
        ? fromHash
        : state.servers[0].name;
      renderTabs();
      await refresh({ force: true });
      await renderBackups();
      schedule();
      if (state.countdownTimer) clearInterval(state.countdownTimer);
      state.countdownTimer = setInterval(tickCountdowns, 1000);

      $("refresh").addEventListener("click", () => refresh({ force: true }));
      $("backup-create").addEventListener("click", async () => {
        const button = $("backup-create");
        button.disabled = true;
        button.textContent = "Creating…";
        try {
          const result = await post("backups", { server: state.current });
          setBanner(`Created ${result.name} (${fmtBytes(result.size)})`, "ok");
          await renderBackups();
        } catch (error) {
          reportError(error);
        } finally {
          button.disabled = false;
          button.textContent = "Create backup";
        }
      });
      document.addEventListener("visibilitychange", () => {
        if (document.visibilityState === "visible") refresh({ force: true });
      });
      window.addEventListener("hashchange", () => {
        const name = location.hash.replace(/^#/, "");
        if (name && name !== state.current) selectServer(name);
      });
    } catch (error) {
      reportError(error);
    }
  }

  boot();
})();
