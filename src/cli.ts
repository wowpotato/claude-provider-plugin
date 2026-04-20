import { Command } from "commander";
import chalk from "chalk";
import { execFileSync } from "node:child_process";
import { listProfiles, detectActiveProfile, switchToProvider } from "./profiles.js";
import { runInteractiveMenu } from "./interactive.js";
import { mcpServer } from "./mcp.js";
import {
  isMacOS,
  isCredentialSwapDisabled,
  captureActiveKeychainBeforeSwitch,
  saveCredentialForProfile,
  restoreCredentialForProfile,
  listSavedCredentials,
} from "./credentials.js";

/**
 * Detect whether a Claude Code CLI process is currently running. When it is,
 * the process has already loaded its OAuth credential into memory for the
 * previously-active plan, so the ongoing session will keep hitting the old
 * plan's rate limits even after we swap keychain/credential files.
 */
function countRunningClaudeProcesses(): number {
  try {
    const out = execFileSync("pgrep", ["-f", "/claude( |$)|claude/versions/"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const pids = out.trim().split("\n").filter(Boolean);
    // Exclude this very process and its parent shell.
    const ownPid = process.pid;
    const ppid = process.ppid;
    return pids.filter((p) => {
      const n = Number(p);
      return !Number.isNaN(n) && n !== ownPid && n !== ppid;
    }).length;
  } catch {
    return 0;
  }
}

function warnIfClaudeRunning(): void {
  const n = countRunningClaudeProcesses();
  if (n > 0) {
    console.warn(
      chalk.yellow(`⚠ ${n} Claude Code session(s) still running with the previous plan's token.`)
    );
    console.warn(
      chalk.yellow("   Exit those sessions (/exit) and start a new `claude` for the swap to apply.")
    );
  }
}

/**
 * Display list of installed providers
 */
function showProviderList(): void {
  const profiles = listProfiles();

  console.log(chalk.bold("Installed providers:"));

  if (!profiles || profiles.length === 0) {
    console.log(chalk.dim("  No providers installed. Run claude-provider to add one."));
    return;
  }

  const active = detectActiveProfile(profiles);

  for (const profile of profiles) {
    const marker = profile.name === active ? chalk.green(" (active)") : "";
    console.log(` - ${profile.name}${marker}`);
  }
}

/**
 * Direct switch to a provider by name
 */
function directSwitch(name: string): void {
  const profiles = listProfiles();
  const exists = profiles.some((p) => p.name.toLowerCase() === name.toLowerCase());

  if (!exists) {
    console.error(chalk.red(`Provider not installed: ${name}`));
    console.error(chalk.dim('Tip: run "claude-provider" or "cpr" to add providers interactively.'));
    process.exit(1);
  }

  // Find exact case-insensitive match
  const profile = profiles.find((p) => p.name.toLowerCase() === name.toLowerCase());
  if (!profile) {
    console.error(chalk.red(`Provider not found: ${name}`));
    process.exit(1);
  }

  // Save the current active profile's keychain BEFORE we overwrite it. Without
  // this, tokens that rotated during the previous Claude Code session get lost
  // the moment we switch, and the next restore brings back stale credentials
  // that make Claude Code 401 on first request.
  if (isMacOS() && !isCredentialSwapDisabled()) {
    const capture = captureActiveKeychainBeforeSwitch(profile.name, profiles);
    if (capture.captured) {
      console.log(
        chalk.dim(`   (captured current keychain → ${capture.path} before switch)`)
      );
    }
  }

  switchToProvider(profile.name);
  console.log(`✅ Switched to ${chalk.cyan(profile.name)}. Run "claude" then /status.`);

  // Personal-branch behavior: auto-swap the keychain OAuth credential
  // whenever a credentials.<profile>.json exists. Users who never saved
  // a credential file see no change; users who did get seamless Pro ↔
  // Team ↔ Enterprise switching on a single Anthropic account.
  if (isMacOS() && !isCredentialSwapDisabled()) {
    const result = restoreCredentialForProfile(profile.name);
    if (result.restored) {
      console.log(chalk.dim(`   (keychain credential restored from ${result.path})`));
    } else if (result.reason && result.reason !== "no saved credential for profile") {
      console.warn(chalk.yellow(`   (credential restore skipped: ${result.reason})`));
    }
  }

  warnIfClaudeRunning();
}

/**
 * Handle `cpr credential <action> [profile]` subcommand.
 */
function handleCredentialCommand(action: string, profile?: string): void {
  if (!isMacOS()) {
    console.error(chalk.red("credential commands are only supported on macOS"));
    process.exit(1);
  }

  switch (action) {
    case "save": {
      if (!profile) {
        console.error(chalk.red("Usage: cpr credential save <profile>"));
        process.exit(1);
      }
      const result = saveCredentialForProfile(profile);
      if (result.saved) {
        console.log(`✅ Saved credential for ${chalk.cyan(profile)} → ${result.path}`);
      } else {
        console.error(chalk.red(`Failed: ${result.reason}`));
        process.exit(1);
      }
      return;
    }
    case "restore": {
      if (!profile) {
        console.error(chalk.red("Usage: cpr credential restore <profile>"));
        process.exit(1);
      }
      const result = restoreCredentialForProfile(profile);
      if (result.restored) {
        console.log(`✅ Restored credential for ${chalk.cyan(profile)} from ${result.path}`);
      } else {
        console.error(chalk.red(`Failed: ${result.reason}`));
        process.exit(1);
      }
      return;
    }
    case "list": {
      const saved = listSavedCredentials();
      if (saved.length === 0) {
        console.log(chalk.dim("No saved credentials. Run `cpr credential save <profile>`."));
        return;
      }
      console.log(chalk.bold("Saved credentials:"));
      for (const name of saved) {
        console.log(` - ${name}`);
      }
      return;
    }
    default:
      console.error(chalk.red(`Unknown action: ${action}`));
      console.error(chalk.dim("Available: save, restore, list"));
      process.exit(1);
  }
}

/**
 * Create and configure the CLI program
 */
export function createProgram(): Command {
  return new Command()
    .name("claude-provider")
    .description("CLI tool to switch between Claude Code API providers")
    .version("0.0.6")
    .argument(
      "[provider]",
      'provider name (e.g. kimi, zai, qwen, minimax, deepseek) or "credential" for keychain subcommand'
    )
    .argument("[action]", 'subcommand action (for "credential" only: save / restore / list)')
    .argument("[profile]", 'profile name (required for "credential save|restore")')
    .option("-l, --list", "list installed providers");
}

/**
 * Run the CLI application
 */
export async function runCli(): Promise<void> {
  const program = createProgram();
  program.parse(process.argv);

  const opts = program.opts<{ list?: boolean }>();
  const provider = program.args[0];

  if (opts.list) {
    showProviderList();
    return;
  }

  if (provider == "mcp") {
    return mcpServer();
  }

  if (provider === "credential") {
    const action = program.args[1];
    const credProfile = program.args[2];
    if (!action) {
      console.error(chalk.red("Usage: cpr credential <save|restore|list> [profile]"));
      process.exit(1);
    }
    handleCredentialCommand(action, credProfile);
    return;
  }

  if (provider) {
    directSwitch(provider);
    return;
  }

  await runInteractiveMenu();
}

runCli().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
