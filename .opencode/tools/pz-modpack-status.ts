import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { execSync } from "node:child_process";

/**
 * Read-only status tool for this project's modpack catalogue, and for the
 * Project Zomboid servers a consuming NixOS config declares.
 *
 * The catalogue lives HERE, in `modpacks/`, and is exported as the flake output
 * `self.modpacks`. Server definitions do NOT live here — a consumer keeps them
 * in its own config under `services.project-zomboid-servers.servers`, usually
 * one file per server. So this tool has two independent halves, and the servers
 * half is optional.
 */

function repoRoot(): string {
  try {
    return execSync("git rev-parse --show-toplevel 2>/dev/null", { encoding: "utf-8" }).trim() || process.env.PWD || ".";
  } catch {
    return process.env.PWD || ".";
  }
}

/** Steam Workshop item IDs declared as `id = "<digits>"` in a .nix file. */
function workshopIds(file: string): string[] {
  const src = readFileSync(file, "utf-8");
  const ids: string[] = [];
  for (const m of src.matchAll(/id\s*=\s*"(\d+)"/g)) ids.push(m[1]);
  return [...new Set(ids)];
}

/** `modpacks/*.nix` in this repo, excluding the default.nix aggregator. */
function catalogueFiles(repo: string): string[] {
  const dir = join(repo, "modpacks");
  try {
    return readdirSync(dir)
      .filter((n) => n.endsWith(".nix") && n !== "default.nix")
      .sort();
  } catch {
    return [];
  }
}

/**
 * Pack names as the flake actually resolves them, which is authoritative over
 * whatever is on disk. Flake inputs and `nix` being unavailable is entirely
 * normal (this repo is consumed as a private flake input on a cold machine), so
 * a failure here is not an error — the caller falls back to the directory.
 */
function catalogueViaNix(repo: string): string[] | null {
  try {
    const out = execSync(
      // Parenthesis the getFlake call: `x.modpacks | builtins.attrNames` puts
      // the pipe outside the attribute selection and `nix eval` rejects it.
      `nix eval --impure --json --expr '(builtins.attrNames (builtins.getFlake "path:${repo}").modpacks)'`,
      { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"], timeout: 120_000 },
    );
    const names = JSON.parse(out);
    return Array.isArray(names) && names.length ? names.sort() : null;
  } catch {
    return null;
  }
}

/** A consumer's per-server files, if this repo happens to be a NixOS config. */
function consumerServerDir(repo: string): string | null {
  const dir = join(repo, "modules", "nixos", "projectzomboid-server", "servers");
  if (!existsSync(dir)) return null;
  return dir;
}

function listNixFiles(dir: string): string[] {
  try {
    return readdirSync(dir)
      .filter((n) => n.endsWith(".nix") && n !== "default.nix")
      .sort();
  } catch {
    return [];
  }
}

export default {
  description:
    "Inspect the Project Zomboid modpack catalogue in this repo (modpacks/) and, if this is also a NixOS config, the servers it declares: report the packs and servers present and the Steam Workshop item IDs each declares. Read-only status tool.",
  args: {
    modpack: {
      type: "string",
      description: "Optional modpack name to detail (e.g. 'vanilla-plus'). Omit to summarize all.",
    },
  },
  async execute(args: { modpack?: string }) {
    const repo = repoRoot();
    const lines: string[] = [];

    // ── Catalogue ──────────────────────────────────────────────────────────
    // Only meaningful when run against THIS repo. A consuming NixOS config has
    // no `modpacks/` directory and no `.modpacks` flake output, and saying
    // "(none)" there would read like an empty catalogue rather than "wrong repo".
    const files = catalogueFiles(repo);
    const isCatalogueRepo = files.length > 0 || existsSync(join(repo, "modpacks"));
    const viaNix = isCatalogueRepo ? catalogueViaNix(repo) : null;
    const names = viaNix ?? files.map((f) => f.replace(/\.nix$/, ""));

    lines.push(`repo:            ${repo}`);
    if (!isCatalogueRepo) {
      lines.push("modpacks:        (n/a — not the catalogue repo; run this from nixos-projectzomboid-servers)");
    } else {
      lines.push(`modpacks:        ${names.length ? names.join(", ") : "(none)"}`);
      if (viaNix) lines.push(`                 (names resolved via 'nix eval' on self.modpacks)`);
      else if (files.length) lines.push(`                 (read from modpacks/ — 'nix eval' unavailable)`);
    }

    if (args.modpack) {
      const name = args.modpack;
      const file = join(repo, "modpacks", `${name}.nix`);

      if (!isCatalogueRepo) {
        lines.push("");
        lines.push(
          `No modpack '${name}' — '${repo}' is not the catalogue repo. ` +
            `Packs live in nixos-projectzomboid-servers/modpacks/, or are read from a consumer's ` +
            `services.project-zomboid-servers.modpacks at flake-eval time.`,
        );
        return lines.join("\n");
      }

      if (!names.includes(name)) {
        lines.push("");
        lines.push(`No modpack '${name}'. Available: ${names.join(", ") || "(none)"}`);
        return lines.join("\n");
      }

      // Prefer the file for the ids; it is the source the catalogue imports.
      const ids = existsSync(file) ? workshopIds(file) : [];
      lines.push("");
      lines.push(`Modpack '${name}':`);
      lines.push(`  workshop item IDs (${ids.length}): ${ids.join(", ") || "(none)"}`);
      for (const id of ids) {
        lines.push(`    https://steamcommunity.com/sharedfiles/filedetails/?id=${id}`);
      }
    } else if (files.length) {
      lines.push("");
      for (const f of files) {
        const ids = workshopIds(join(repo, "modpacks", f));
        const name = f.replace(/\.nix$/, "");
        const preview = ids.slice(0, 4).join(", ") + (ids.length > 4 ? "…" : "");
        lines.push(`  - ${name}: ${ids.length} workshop item(s)${ids.length ? ` — ${preview}` : ""}`);
      }
    }

    // ── Consumer servers, when this repo is also a NixOS config ────────────
    const serversDir = consumerServerDir(repo);
    lines.push("");
    if (serversDir) {
      const servers = listNixFiles(serversDir);
      lines.push(`servers:         ${servers.length ? servers.map((s) => s.replace(/\.nix$/, "")).join(", ") : "(none)"}`);
      lines.push(`                 (${resolve(serversDir)} — services.project-zomboid-servers.servers)`);
      if (!args.modpack) {
        for (const s of servers) {
          const src = readFileSync(join(serversDir, s), "utf-8");
          const enabled = /enable\s*=\s*lib\.mkDefault\s+false/.test(src) ? "disabled (opt in)" : "enabled";
          const pack = src.match(/modpack\s*=\s*"([^"]+)"/)?.[1] ?? "(none)";
          const ids = workshopIds(join(serversDir, s));
          lines.push(`  - ${s.replace(/\.nix$/, "")}: ${enabled}, modpack=${pack}, ${ids.length} inline workshop item(s)`);
        }
      }
    } else {
      lines.push("servers:         (none here — this is the module repo, not a NixOS config)");
      lines.push("                 consumers declare services.project-zomboid-servers.servers in their own tree");
    }

    return lines.join("\n");
  },
};