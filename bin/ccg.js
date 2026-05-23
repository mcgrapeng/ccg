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
const { spawnSync, execFileSync } = require("node:child_process");

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
  try {
    execFileSync(process.platform === "win32" ? "where" : "command", ["-v", cmd], {
      stdio: "ignore",
      shell: true,
    });
    return true;
  } catch {
    // Fallback for systems where `command -v` cannot be located via execFile
    const r = spawnSync("sh", ["-c", `command -v "${cmd}" >/dev/null 2>&1`]);
    return r.status === 0;
  }
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

function cmdVersion() {
  console.log(PKG.version);
}

function cmdHelp() {
  console.log(`${C.bold}@mcgrapeng/ccg${C.reset} v${PKG.version} — Code Divergence Detector

${C.bold}Usage${C.reset}
  npx @mcgrapeng/ccg install      Install /ccg into ~/.claude/commands/
  npx @mcgrapeng/ccg uninstall    Remove the slash command
  npx @mcgrapeng/ccg doctor       Verify Codex / Gemini / API key
  npx @mcgrapeng/ccg version      Print version
  npx @mcgrapeng/ccg help         Show this message

${C.bold}After install${C.reset}
  Open Claude Code → type ${C.bold}/ccg${C.reset} on a diff.

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
