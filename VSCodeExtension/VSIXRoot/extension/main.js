"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");

const requestDirectory = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Turnring",
  "focus-requests"
);

function isValidRequestID(value) {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
}

function isValidSessionID(value) {
  return typeof value === "string" &&
    value.length >= 6 &&
    value.length <= 200 &&
    /^[A-Za-z0-9._:-]+$/.test(value);
}

function readRequest(requestID) {
  if (!isValidRequestID(requestID)) {
    throw new Error("Invalid Turnring request identifier.");
  }

  const requestPath = path.join(requestDirectory, `${requestID}.json`);
  const details = fs.lstatSync(requestPath);
  if (!details.isFile() || details.uid !== process.getuid() || (details.mode & 0o022) !== 0) {
    throw new Error("Turnring rejected an unsafe focus request.");
  }
  if (details.size > 64 * 1024) {
    throw new Error("Turnring focus request is too large.");
  }

  let request;
  try {
    request = JSON.parse(fs.readFileSync(requestPath, "utf8"));
  } finally {
    fs.unlinkSync(requestPath);
  }
  if (request.requestID !== requestID) {
    throw new Error("Turnring request identifier mismatch.");
  }
  const createdAt = Date.parse(request.createdAt);
  const age = Date.now() - createdAt;
  if (!Number.isFinite(createdAt) || age < -60_000 || age > 5 * 60_000) {
    throw new Error("Turnring focus request expired.");
  }
  return request;
}

async function focusTerminal(shellPID) {
  if (!Number.isSafeInteger(shellPID) || shellPID <= 1) {
    return false;
  }
  for (const terminal of vscode.window.terminals) {
    try {
      if (await terminal.processId === shellPID) {
        terminal.show(false);
        return true;
      }
    } catch {
      // A terminal can disappear while its process identifier is being resolved.
    }
  }
  return false;
}

function validatedResumeOptions(request) {
  const provider = request.provider;
  if (provider !== "codex" && provider !== "claude") {
    throw new Error("Unsupported agent provider.");
  }
  if (!isValidSessionID(request.sessionID)) {
    throw new Error("Invalid saved session identifier.");
  }

  const executablePath = request.executablePath;
  if (typeof executablePath !== "string" || !path.isAbsolute(executablePath)) {
    throw new Error("Invalid saved executable path.");
  }
  const executableName = path.basename(executablePath).toLowerCase();
  const allowedNames = provider === "codex" ? ["codex"] : ["claude", "claude.exe"];
  if (!allowedNames.includes(executableName) || !fs.statSync(executablePath).isFile()) {
    throw new Error("Saved agent executable is unavailable.");
  }

  const cwd = request.cwd;
  if (typeof cwd !== "string" || !path.isAbsolute(cwd) || !fs.statSync(cwd).isDirectory()) {
    throw new Error("Saved project directory is unavailable.");
  }

  return {
    cwd,
    shellPath: executablePath,
    shellArgs: provider === "codex"
      ? ["resume", request.sessionID]
      : ["--resume", request.sessionID],
    name: `Turnring · ${provider === "codex" ? "Codex" : "Claude"}`
  };
}

async function handleURI(uri) {
  if (uri.authority !== "turnring.focus" || uri.path !== "/focus") {
    return;
  }

  try {
    const parameters = new URLSearchParams(uri.query);
    const request = readRequest(parameters.get("request"));
    if (request.action === "focus") {
      if (!await focusTerminal(request.shellPID)) {
        vscode.window.showWarningMessage(
          "Turnring could not identify the original terminal. It did not start a duplicate session."
        );
      }
      return;
    }

    if (request.action !== "resume") {
      throw new Error("Unsupported Turnring action.");
    }
    const terminal = vscode.window.createTerminal(validatedResumeOptions(request));
    terminal.show(false);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown focus error.";
    vscode.window.showErrorMessage(`Turnring: ${message}`);
  }
}

function activate(context) {
  context.subscriptions.push(vscode.window.registerUriHandler({ handleUri: handleURI }));
}

function deactivate() {}

module.exports = { activate, deactivate };
