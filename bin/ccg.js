#!/usr/bin/env node
/**
 * @mcgrapeng/ccg — Node.js CLI entry.
 *
 * Subcommands:
 *   install     install /ccg slash command into ~/.claude/commands/
 *   uninstall   remove the slash command
 *   doctor      preflight: check Codex CLI, Gemini CLI, GEMINI_API_KEY
 *   version     print version
 *   help        show this message
 *
 * The CLI is a thin orchestrator. All review logic lives in the bash core
 * (ccg.sh), which gets installed into ~/.claude/commands/ as a slash command.
 *
 * Source: https://github.com/mcgrapeng/ccg
 */

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync } = require("node:child_process");

const PKG_ROOT = path.resolve(__dirname, "..");
const PKG = require(path.join(PKG_ROOT, "package.json"));

const CCG_SH = path.join(PKG_ROOT, "ccg.sh");
const CCG_MD = path.join(PKG_ROOT, "ccg.md");
const TARGET_DIR = path.join(os.homedir(), ".claude", "commands");

// ──────────────────────────────────────────────────────────────
// pretty helpers
// ──────────────────────────────────────────────────────────────
const TTY = process.stdout.isTTY;
const C = {
  reset: TTY ? "\x1b[0m" : "",
  dim: TTY ? "\x1b[2m" : "",
  bold: TTY ? "\x1b[1m" : "",
  green: TTY ? "\x1b[32m" : "",
  red: TTY ? "\x1b[31m" : "",
  yellow: TTY ? "\x1b[33m" : "",
  cyan: TTY ? "\x1b[36m" : "",
};
const ok = (m) => console.log(`${C.green}✓${C.reset} ${m}`);
const warn = (m) => console.log(`${C.yellow}!${C.reset} ${m}`);
const fail = (m) => console.error(`${C.red}✗${C.reset} ${m}`);
const head = (m) => console.log(`\n${C.bold}${m}${C.reset}`);

// ──────────────────────────────────────────────────────────────
// commands
// ──────────────────────────────────────────────────────────────
function which(cmd) {
  // Validate cmd to prevent command injection — only allow simple alphanumeric + hyphen/underscore
  if (!/^[a-zA-Z0-9_-]+$/.test(cmd)) {
    return false;
  }
  if (process.platform === "win32") {
    const r = spawnSync("where", [cmd], { stdio: "ignore" });
    return r.status === 0;
  }
  // `command` is a shell builtin (no standalone binary), so run it via `sh -c`.
  // cmd is validated above and passed as a positional arg — never interpolated
  // into the script string — so this is injection-safe.
  const r = spawnSync("sh", ["-c", 'command -v "$1" >/dev/null 2>&1', "--", cmd]);
  return r.status === 0;
}

function cmdInstall() {
  head("Installing /ccg slash command for Claude Code");

  if (!fs.existsSync(CCG_SH) || !fs.existsSync(CCG_MD)) {
    fail("Package payload missing (ccg.sh / ccg.md). Reinstall the npm package.");
    process.exit(2);
  }

  fs.mkdirSync(TARGET_DIR, { recursive: true });
  fs.copyFileSync(CCG_SH, path.join(TARGET_DIR, "ccg.sh"));
  fs.chmodSync(path.join(TARGET_DIR, "ccg.sh"), 0o755);
  fs.copyFileSync(CCG_MD, path.join(TARGET_DIR, "ccg.md"));
  fs.chmodSync(path.join(TARGET_DIR, "ccg.md"), 0o644);

  ok(`wrote ${path.join(TARGET_DIR, "ccg.sh")}`);
  ok(`wrote ${path.join(TARGET_DIR, "ccg.md")}`);

  cmdDoctor({ silent: false, exitOnFail: false });

  console.log("");
  console.log(`${C.cyan}Next:${C.reset} open Claude Code and type ${C.bold}/ccg${C.reset} on a diff.`);
}

function cmdUninstall() {
  head("Uninstalling /ccg slash command");
  let removed = 0;
  for (const f of ["ccg.sh", "ccg.md"]) {
    const p = path.join(TARGET_DIR, f);
    if (fs.existsSync(p)) {
      fs.unlinkSync(p);
      ok(`removed ${p}`);
      removed += 1;
    }
  }
  if (removed === 0) warn("Nothing to remove (slash command was not installed).");
  console.log(`\n${C.dim}User data (cache / ledger) was NOT touched — they live under XDG paths.${C.reset}`);
}

function cmdDoctor({ silent = false, exitOnFail = true } = {}) {
  if (!silent) head("Preflight checks");

  const hasCodex = which("codex");
  const hasGemini = which("gemini");
  const hasGeminiKey = Boolean(
    process.env.GEMINI_API_KEY && process.env.GEMINI_API_KEY.trim(),
  );

  const results = [
    {
      label: "Codex CLI (codex)",
      pass: hasCodex,
      hint: "npm i -g @openai/codex",
    },
    {
      label: "Gemini CLI (gemini)",
      pass: hasGemini,
      hint: "npm i -g @google/gemini-cli",
    },
    {
      label: "GEMINI_API_KEY environment variable",
      pass: hasGeminiKey,
      hint: 'put `export GEMINI_API_KEY="..."` into ~/.zshenv (works in non-interactive shells)',
    },
  ];

  let anyFail = false;
  for (const r of results) {
    if (r.pass) ok(r.label);
    else {
      warn(`${r.label} ${C.dim}→ ${r.hint}${C.reset}`);
      anyFail = true;
    }
  }

  if (!silent) {
    if (!anyFail) {
      console.log(`\n${C.green}All checks passed.${C.reset} /ccg is ready.`);
    } else if (hasCodex || hasGemini) {
      console.log(
        `\n${C.yellow}/ccg can run in degraded single-source mode.${C.reset} Install the missing tool for full divergence detection.`,
      );
    } else {
      console.log(
        `\n${C.red}/ccg cannot run yet — install at least one of Codex/Gemini and ensure GEMINI_API_KEY for full features.${C.reset}`,
      );
    }
  }

  if (exitOnFail && anyFail) process.exitCode = 1;
}

// ──────────────────────────────────────────────────────────────
// `ccg about` — 7-layer capability probe
//
// Shows what ccg can do in this environment, not what the README claims.
// Each layer is independently usable; layers below answer real engineering
// problems even if you never touch the divergence-detection layer above.
// ──────────────────────────────────────────────────────────────
function cmdAbout() {
  const xdg = {
    config: process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"),
    cache: process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"),
    data: process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local/share"),
  };
  const cacheDir = path.join(xdg.cache, "ccg", "cache");
  const dataDir = path.join(xdg.data, "ccg");
  const ledger = path.join(dataDir, "ledger.jsonl");
  const usageLog = path.join(dataDir, "usage.log");

  const hasCodex = which("codex");
  const hasGemini = which("gemini");
  const hasGeminiKey = Boolean(
    process.env.GEMINI_API_KEY && process.env.GEMINI_API_KEY.trim(),
  );
  const hasGit = which("git");
  const installedSlash =
    fs.existsSync(path.join(TARGET_DIR, "ccg.sh")) &&
    fs.existsSync(path.join(TARGET_DIR, "ccg.md"));
  const fileExists = (p) => {
    try { return fs.statSync(p).isFile(); } catch { return false; }
  };
  const countLines = (p) => {
    try {
      return fs
        .readFileSync(p, "utf8")
        .split("\n")
        .filter((line) => line.trim().length > 0).length;
    } catch { return 0; }
  };
  const dirSize = (p) => {
    try {
      let total = 0;
      for (const entry of fs.readdirSync(p, { withFileTypes: true })) {
        const full = path.join(p, entry.name);
        if (entry.isFile()) total += fs.statSync(full).size;
      }
      return total;
    } catch { return 0; }
  };
  const fmtSize = (b) =>
    b < 1024 ? `${b}B` : b < 1024 ** 2 ? `${(b / 1024).toFixed(1)}KB` : `${(b / 1024 ** 2).toFixed(1)}MB`;

  const ledgerEntries = countLines(ledger);
  const usageEntries = countLines(usageLog);
  const cacheSize = dirSize(cacheDir);

  // ── header ────────────────────────────────────────────
  console.log(`${C.bold}@mcgrapeng/ccg${C.reset} v${PKG.version}`);
  console.log(`${C.dim}A production-grade orchestrator for using Codex + Gemini CLI from inside Claude Code.${C.reset}`);
  console.log("");
  console.log(`Source:  ${PKG.repository.url.replace(/^git\+/, "").replace(/\.git$/, "")}`);
  console.log("");

  // ── 7-layer capability matrix ─────────────────────────
  console.log(`${C.bold}7 layers of capability${C.reset}`);
  console.log(`${C.dim}(Each layer is useful on its own. The famous "divergence detection" is just L7.)${C.reset}`);
  console.log("");

  const layers = [
    {
      id: "L1",
      name: "Safe CLI scheduling",
      solves: "timeouts / stdin preservation / secret redaction / cleanup safety",
      status: "always-on",
      detail: `cleanup, mktemp 700, 7-pattern redaction (sk-/AIza/Bearer/JWT/ghp_/AKIA/Slack)`,
    },
    {
      id: "L2",
      name: "Content-addressed cache",
      solves: "stop paying for the same prompt twice during debugging",
      status: process.env.CCG_NO_CACHE === "1" ? "disabled (CCG_NO_CACHE=1)" : "always-on",
      detail: `SHA-256 prompt + model key, 24h TTL, failed calls NOT cached.  Current: ${fmtSize(cacheSize)} at ${cacheDir}`,
    },
    {
      id: "L3",
      name: "Smart diff capture",
      solves: "captures changes even after you've committed them",
      status: hasGit ? "ready" : "git missing",
      detail: "4-level fallback: worktree → staged → upstream → origin-head (reports CCG_DIFF_SOURCE)",
    },
    {
      id: "L4",
      name: "Usage tracking & cost telemetry",
      solves: "see how much you spend per month / per model",
      status: "always-on",
      detail: `${usageEntries} call(s) logged at ${usageLog}.  Run: ${C.cyan}source ccg.sh && ccg_usage --this-month${C.reset}`,
    },
    {
      id: "L5",
      name: "Risk-aware auto routing",
      solves: "auto-pick cost/balanced/quality based on path+content+size",
      status: "always-on",
      detail: "Pure rule scoring (no LLM). Path matches auth/payment → +25..+40; SQL+interp → +30; docs only → -40",
    },
    {
      id: "L6",
      name: "Review ledger",
      solves: "stateless AI can't tell you 'what did the model say last time on src/auth.ts?'",
      status: "always-on",
      detail: `${ledgerEntries} review(s) logged at ${ledger}.  Query: ${C.cyan}ccg_ledger_query "src/auth"${C.reset}`,
    },
    {
      id: "L7",
      name: "Divergence detection (synthesis)",
      solves: "single-model review can't see its own blind spots",
      status:
        hasCodex && hasGemini && hasGeminiKey
          ? "full (Codex + Gemini)"
          : hasCodex || (hasGemini && hasGeminiKey)
          ? "degraded (single source)"
          : "unavailable",
      detail: "Codex + Gemini → same prompt → Claude surfaces AGREEMENT / DIVERGENCE / BLINDSPOT",
    },
  ];

  for (const layer of layers) {
    const isFull =
      layer.status.includes("ready") ||
      layer.status === "always-on" ||
      layer.status.startsWith("full");
    const isDegraded = layer.status.startsWith("degraded") || layer.status.includes("disabled");
    const isFail =
      layer.status.includes("missing") || layer.status.includes("unavailable");

    const dot = isFull
      ? `${C.green}●${C.reset}`
      : isDegraded
      ? `${C.yellow}●${C.reset}`
      : isFail
      ? `${C.red}●${C.reset}`
      : `${C.dim}●${C.reset}`;
    console.log(`  ${dot} ${C.bold}${layer.id}${C.reset}  ${layer.name}  ${C.dim}— ${layer.status}${C.reset}`);
    console.log(`     ${C.dim}why:${C.reset}    ${layer.solves}`);
    console.log(`     ${C.dim}how:${C.reset}    ${layer.detail}`);
    console.log("");
  }

  // ── environment ─────────────────────────────────────────
  console.log(`${C.bold}Environment${C.reset}`);
  const envRow = (label, status, hint) => {
    const dot = status ? `${C.green}✓${C.reset}` : `${C.red}✗${C.reset}`;
    console.log(`  ${dot}  ${label}${status ? "" : `  ${C.dim}→ ${hint}${C.reset}`}`);
  };
  envRow("Claude Code slash command installed", installedSlash, `run: ${C.cyan}ccg install${C.reset}`);
  envRow("Codex CLI", hasCodex, "npm i -g @openai/codex");
  envRow("Gemini CLI", hasGemini, "npm i -g @google/gemini-cli");
  envRow("GEMINI_API_KEY env var", hasGeminiKey, 'add to ~/.zshenv: export GEMINI_API_KEY="..."');
  envRow("git available", hasGit, "install git for diff capture");
  console.log("");

  // ── storage ─────────────────────────────────────────────
  console.log(`${C.bold}Storage (XDG)${C.reset}`);
  console.log(`  config:  ${path.join(xdg.config, "ccg")}/${fileExists(path.join(xdg.config, "ccg/config.json")) ? "" : `  ${C.dim}(no config.json yet)${C.reset}`}`);
  console.log(`  cache:   ${cacheDir}  ${C.dim}(${fmtSize(cacheSize)})${C.reset}`);
  console.log(`  data:    ${dataDir}  ${C.dim}(ledger=${ledgerEntries}, usage=${usageEntries})${C.reset}`);
  console.log("");

  // ── quick reference ────────────────────────────────────
  console.log(`${C.bold}Common commands${C.reset}`);
  console.log(`  ${C.cyan}/ccg${C.reset}                                          ${C.dim}(inside Claude Code) full divergence review on current diff${C.reset}`);
  console.log(`  ${C.cyan}source ~/.claude/commands/ccg.sh${C.reset}`);
  console.log(`    ${C.cyan}ccg_usage --this-month${C.reset}                      ${C.dim}month-to-date cost${C.reset}`);
  console.log(`    ${C.cyan}ccg_ledger_query "path/fragment"${C.reset}             ${C.dim}past reviews touching a path${C.reset}`);
  console.log(`    ${C.cyan}ccg_risk_score <diff_file>${C.reset}                   ${C.dim}preview routing decision${C.reset}`);
  console.log("");
  console.log(`  ${C.cyan}ccg doctor${C.reset}                                    ${C.dim}re-check environment${C.reset}`);
  console.log(`  ${C.cyan}ccg uninstall${C.reset}                                 ${C.dim}remove slash command (user data preserved)${C.reset}`);
}

function cmdVersion() {
  console.log(PKG.version);
}

function cmdConfig(args) {
  const configDir = path.join(os.homedir(), ".config", "ccg");
  const configFile = path.join(configDir, "config");

  // Helper to run bash functions
  function runBash(func) {
    const r = spawnSync("bash", [
      "-c",
      `source "${CCG_SH}" 2>/dev/null; ${func}`
    ], { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
    return r.stdout || "";
  }

  const subcmd = args[0] || "list";

  switch (subcmd) {
    case "init":
      console.log(runBash("_ccg_config_init"));
      break;

    case "set": {
      const key = args[1];
      const value = args[2];
      if (!key || !value) {
        fail("Usage: ccg config set KEY VALUE");
        process.exit(1);
      }
      console.log(runBash(`_ccg_config_set "${key}" "${value}"`));
      break;
    }

    case "get": {
      const key = args[1];
      if (!key) {
        fail("Usage: ccg config get KEY");
        process.exit(1);
      }
      const result = runBash(`_ccg_config_get "${key}"`);
      if (result.trim()) {
        console.log(result.trim());
      } else {
        console.log(`Key '${key}' not found in config`);
      }
      break;
    }

    case "list":
    case "show":
      console.log(runBash("_ccg_config_list"));
      break;

    case "path":
      console.log(configFile);
      break;

    case "edit": {
      const editor = process.env.EDITOR || process.env.VISUAL || "vi";
      const r = spawnSync(editor, [configFile], { stdio: "inherit" });
      if (r.error) {
        fail(`Cannot open editor: ${editor}`);
        console.log(`\nEdit manually: ${configFile}`);
      }
      break;
    }

    default:
      console.log(`${C.bold}Usage:${C.reset}`);
      console.log(`  ccg config init          Create config file with template`);
      console.log(`  ccg config set KEY VALUE Set a config value`);
      console.log(`  ccg config get KEY       Get a config value`);
      console.log(`  ccg config list          List all config values`);
      console.log(`  ccg config path          Show config file path`);
      console.log(`  ccg config edit          Open config in editor`);
      console.log("");
      console.log(`${C.dim}Config file: ${configFile}${C.reset}`);
      console.log(`${C.dim}Environment variables override config file values.${C.reset}`);
      break;
  }
}

function cmdHelp() {
  console.log(`${C.bold}@mcgrapeng/ccg${C.reset} v${PKG.version} — Code Change Guardian

${C.bold}Usage${C.reset}
  npx @mcgrapeng/ccg install      Install /ccg into ~/.claude/commands/
  npx @mcgrapeng/ccg uninstall    Remove the slash command
  npx @mcgrapeng/ccg about        What can ccg do? 7-layer capability probe
  npx @mcgrapeng/ccg doctor       Verify Codex / Gemini / API key
  npx @mcgrapeng/ccg config       Manage configuration file
  npx @mcgrapeng/ccg version      Print version
  npx @mcgrapeng/ccg help         Show this message

${C.bold}Configuration${C.reset}
  ccg config init          Create config file with template
  ccg config set KEY VALUE Set a config value (e.g., ccg config set DEEPSEEK_API_KEY sk-xxx)
  ccg config get KEY       Get a config value
  ccg config list          List all config values
  ccg config path          Show config file path
  ccg config edit          Open config in editor

${C.bold}After install${C.reset}
  1. Run ${C.bold}ccg config init${C.reset} to create config file
  2. Edit ${C.bold}~/.config/ccg/config${C.reset} to set API keys
  3. Open Claude Code → type ${C.bold}/ccg${C.reset} on a diff

${C.bold}Source${C.reset}  ${PKG.repository.url.replace(/^git\+/, "").replace(/\.git$/, "")}
${C.bold}License${C.reset} ${PKG.license}`);
}

// ──────────────────────────────────────────────────────────────
// dispatch
// ──────────────────────────────────────────────────────────────
const [, , subcommand = "help", ...rest] = process.argv;
const dispatch = {
  install: cmdInstall,
  uninstall: cmdUninstall,
  remove: cmdUninstall,
  doctor: cmdDoctor,
  preflight: cmdDoctor,
  about: cmdAbout,
  capabilities: cmdAbout,
  caps: cmdAbout,
  config: cmdConfig,
  cfg: cmdConfig,
  version: cmdVersion,
  "-v": cmdVersion,
  "--version": cmdVersion,
  help: cmdHelp,
  "-h": cmdHelp,
  "--help": cmdHelp,
};

const action = dispatch[subcommand];
if (!action) {
  fail(`Unknown subcommand: ${subcommand}`);
  cmdHelp();
  process.exit(2);
}

try {
  action(rest);
} catch (err) {
  fail(err.message || String(err));
  process.exit(1);
}
