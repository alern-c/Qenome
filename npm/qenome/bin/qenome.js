#!/usr/bin/env node
"use strict";

const { spawn, execFileSync } = require("child_process");
const { chmodSync, existsSync } = require("fs");
const { join } = require("path");

const packages = {
  "darwin-arm64": "@qenome/darwin-arm64",
  "darwin-x64": "@qenome/darwin-x64",
  "linux-arm64": "@qenome/linux-arm64",
  "linux-x64": "@qenome/linux-x64",
};

function fail(message) {
  process.stderr.write("qenome: " + message + "\n");
  process.exit(1);
}

function clearQuarantine(binary) {
  if (process.platform !== "darwin") {
    return;
  }
  try {
    execFileSync("xattr", ["-d", "com.apple.quarantine", binary], {
      stdio: "ignore",
    });
  } catch (error) {
    return error;
  }
}

function binaryPath() {
  const key = process.platform + "-" + process.arch;
  const name = packages[key];
  if (!name) {
    fail(
      "no npm binary for " +
        process.platform +
        "/" +
        process.arch +
        ". Supported targets are linux/x64, linux/arm64, darwin/x64, and darwin/arm64."
    );
  }
  let manifest;
  try {
    manifest = require.resolve(name + "/package.json");
  } catch (error) {
    fail(
      "could not find " +
        name +
        " (" +
        error.code +
        "). Reinstall qenome so npm can fetch the optional package for this machine."
    );
  }
  const binary = join(manifest, "..", "bin", "qenome");
  if (!existsSync(binary)) {
    fail("could not find the binary at " + binary);
  }
  try {
    chmodSync(binary, 0o755);
  } catch (error) {
    fail("could not mark the binary executable: " + error.message);
  }
  clearQuarantine(binary);
  return binary;
}

const child = spawn(binaryPath(), process.argv.slice(2), { stdio: "inherit" });

child.on("error", function (error) {
  fail("failed to start: " + error.message);
});

child.on("exit", function (code, signal) {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code === null ? 1 : code);
});
