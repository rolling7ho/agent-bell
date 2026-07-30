#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const [sourceRootArgument, outputRootArgument] = process.argv.slice(2);
if (!sourceRootArgument || !outputRootArgument) {
  throw new Error("Usage: package-vsix.mjs <VSIXRoot> <output-directory>");
}

const sourceRoot = path.resolve(sourceRootArgument);
const outputRoot = path.resolve(outputRootArgument);
const expectedFiles = [
  "[Content_Types].xml",
  "extension.vsixmanifest",
  "extension/README.md",
  "extension/main.js",
  "extension/package.json",
];

function listFiles(root, relativeDirectory = "") {
  const directory = path.join(root, relativeDirectory);
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const relativePath = path.posix.join(relativeDirectory, entry.name);
    const absolutePath = path.join(root, relativePath);
    const details = fs.lstatSync(absolutePath);
    if (details.isSymbolicLink()) {
      throw new Error(`VSIX input must not contain symlinks: ${relativePath}`);
    }
    if (details.isDirectory()) {
      files.push(...listFiles(root, relativePath));
    } else if (details.isFile()) {
      files.push(relativePath);
    } else {
      throw new Error(`Unsupported VSIX input: ${relativePath}`);
    }
  }
  return files;
}

function readQuotedToken(source, start, quote) {
  let index = start + 1;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === quote) {
      return index + 1;
    }
    index += 1;
  }
  throw new Error("Unterminated JavaScript string or template literal.");
}

function readRegularExpression(source, start) {
  let index = start + 1;
  let inCharacterClass = false;
  while (index < source.length) {
    const character = source[index];
    if (character === "\\") {
      index += 2;
      continue;
    }
    if (character === "[") {
      inCharacterClass = true;
    } else if (character === "]") {
      inCharacterClass = false;
    } else if (character === "/" && !inCharacterClass) {
      index += 1;
      while (/[A-Za-z]/.test(source[index] ?? "")) {
        index += 1;
      }
      return index;
    }
    index += 1;
  }
  throw new Error("Unterminated JavaScript regular expression.");
}

function isIdentifierStart(character) {
  return /[A-Za-z_$]/.test(character);
}

function isIdentifierPart(character) {
  return /[A-Za-z0-9_$]/.test(character);
}

function needsSeparator(previousCharacter, nextCharacter) {
  if (!previousCharacter || !nextCharacter) {
    return false;
  }
  if (
    isIdentifierPart(previousCharacter)
    && isIdentifierPart(nextCharacter)
  ) {
    return true;
  }
  return (
    (previousCharacter === "+" && nextCharacter === "+")
    || (previousCharacter === "-" && nextCharacter === "-")
    || (previousCharacter === "/" && nextCharacter === "/")
  );
}

function mayStartRegularExpression(previousToken) {
  return previousToken === ""
    || [
      "(", "[", "{", ",", "=", ":", ";", "!", "?", "&", "|",
      "return", "case", "throw", "=>",
    ].includes(previousToken);
}

function minifyJavaScript(source) {
  const renamedIdentifiers = new Map([
    ["fs", "_a"],
    ["os", "_b"],
    ["path", "_c"],
    ["vscode", "_d"],
    ["requestDirectory", "_e"],
    ["isValidRequestID", "_f"],
    ["isValidSessionID", "_g"],
    ["readRequest", "_h"],
    ["focusTerminal", "_i"],
    ["validatedResumeOptions", "_j"],
    ["handleURI", "_k"],
    ["requestPath", "_l"],
    ["details", "_m"],
    ["createdAt", "_n"],
    ["executablePath", "_o"],
    ["executableName", "_p"],
    ["allowedNames", "_q"],
    ["parameters", "_r"],
  ]);

  let output = "";
  let index = 0;
  let pendingWhitespace = false;
  let previousToken = "";

  function append(token) {
    if (
      pendingWhitespace
      && needsSeparator(output.at(-1), token[0])
    ) {
      output += " ";
    }
    output += token;
    pendingWhitespace = false;
    previousToken = token;
  }

  while (index < source.length) {
    const character = source[index];
    const nextCharacter = source[index + 1];

    if (/\s/.test(character)) {
      pendingWhitespace = true;
      index += 1;
      continue;
    }
    if (character === "/" && nextCharacter === "/") {
      index += 2;
      while (index < source.length && source[index] !== "\n") {
        index += 1;
      }
      pendingWhitespace = true;
      continue;
    }
    if (character === "/" && nextCharacter === "*") {
      const end = source.indexOf("*/", index + 2);
      if (end < 0) {
        throw new Error("Unterminated JavaScript block comment.");
      }
      index = end + 2;
      pendingWhitespace = true;
      continue;
    }
    if (character === "'" || character === "\"" || character === "`") {
      const end = readQuotedToken(source, index, character);
      append(source.slice(index, end));
      index = end;
      continue;
    }
    if (
      character === "/"
      && mayStartRegularExpression(previousToken)
    ) {
      const end = readRegularExpression(source, index);
      append(source.slice(index, end));
      index = end;
      continue;
    }
    if (isIdentifierStart(character)) {
      let end = index + 1;
      while (end < source.length && isIdentifierPart(source[end])) {
        end += 1;
      }
      const identifier = source.slice(index, end);
      const replacement = previousToken === "."
        ? identifier
        : renamedIdentifiers.get(identifier) ?? identifier;
      append(replacement);
      index = end;
      continue;
    }

    append(character);
    index += 1;
  }

  new vm.Script(output, { filename: "extension/main.js" });
  return output;
}

const actualFiles = listFiles(sourceRoot).sort();
if (JSON.stringify(actualFiles) !== JSON.stringify([...expectedFiles].sort())) {
  throw new Error(
    `Unexpected VSIX contents. Expected ${expectedFiles.join(", ")}; `
      + `found ${actualFiles.join(", ")}.`
  );
}

fs.rmSync(outputRoot, { recursive: true, force: true });
fs.mkdirSync(path.join(outputRoot, "extension"), {
  recursive: true,
  mode: 0o700,
});

for (const relativePath of expectedFiles) {
  const sourcePath = path.join(sourceRoot, relativePath);
  const outputPath = path.join(outputRoot, relativePath);
  const details = fs.statSync(sourcePath);
  if (details.size > 512 * 1024) {
    throw new Error(`VSIX input is unexpectedly large: ${relativePath}`);
  }

  let contents = fs.readFileSync(sourcePath);
  if (relativePath === "extension/main.js") {
    const source = contents.toString("utf8");
    const minified = minifyJavaScript(source);
    if (
      minified.length >= source.length
      || minified.includes("isValidRequestID")
      || minified.includes("validatedResumeOptions")
    ) {
      throw new Error("VSIX JavaScript hardening did not take effect.");
    }
    contents = Buffer.from(minified, "utf8");
  } else if (relativePath === "extension/package.json") {
    contents = Buffer.from(
      JSON.stringify(JSON.parse(contents.toString("utf8"))),
      "utf8"
    );
  }
  fs.writeFileSync(outputPath, contents, { mode: 0o600 });
}

process.stdout.write(`${outputRoot}\n`);
