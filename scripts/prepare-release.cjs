#!/usr/bin/env node

"use strict";

const {
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const stableSemanticVersionPattern =
  /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const projectVersionPattern =
  /^([ \t]*MARKETING_VERSION:[ \t]*)"([^"\r\n]+)"([ \t]*)$/gm;
const generatedVersionPattern =
  /^([ \t]*MARKETING_VERSION = )([^;\r\n]+)(;[ \t]*)$/gm;
const versionAssetPaths = [
  "project.yml",
  "RosterWren.xcodeproj/project.pbxproj",
];

function assertStableSemanticVersion(version, label) {
  if (!stableSemanticVersionPattern.test(version)) {
    throw new Error(`${label} must use stable major.minor.patch format.`);
  }
}

function projectVersion(projectSpec) {
  const matches = [...projectSpec.matchAll(projectVersionPattern)];
  if (matches.length !== 1) {
    throw new Error(
      "project.yml must contain exactly one quoted MARKETING_VERSION setting.",
    );
  }

  const version = matches[0][2];
  assertStableSemanticVersion(version, "The current source version");
  return version;
}

function projectSpecWithVersion(projectSpec, version) {
  assertStableSemanticVersion(version, "The release version");
  projectVersion(projectSpec);

  return projectSpec.replace(
    projectVersionPattern,
    (_match, prefix, _currentVersion, suffix) => (
      `${prefix}"${version}"${suffix}`
    ),
  );
}

function generatedProjectVersions(generatedProject) {
  const versions = [...generatedProject.matchAll(generatedVersionPattern)]
    .map((match) => match[2].trim());
  if (versions.length === 0) {
    throw new Error(
      "The generated Xcode project does not contain MARKETING_VERSION settings.",
    );
  }
  return versions;
}

function generatedProjectWithVersion(generatedProject, version) {
  assertStableSemanticVersion(version, "The release version");
  generatedProjectVersions(generatedProject);
  return generatedProject.replace(
    generatedVersionPattern,
    (_match, prefix, _currentVersion, suffix) => (
      `${prefix}${version}${suffix}`
    ),
  );
}

function writeAtomically(filePath, contents) {
  const temporaryPath = `${filePath}.rosterwren-version-${process.pid}`;
  const mode = statSync(filePath).mode;
  writeFileSync(temporaryPath, contents, { mode });
  renameSync(temporaryPath, filePath);
}

function worktreeChanges(repositoryRoot) {
  const output = execFileSync(
    "git",
    ["status", "--porcelain=v1", "--untracked-files=all"],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
    },
  );

  return output
    .split("\n")
    .filter(Boolean)
    .map((line) => line.slice(3));
}

function samePaths(actualPaths, expectedPaths) {
  const actual = [...new Set(actualPaths)].sort();
  const expected = [...new Set(expectedPaths)].sort();
  return actual.length === expected.length
    && actual.every((entry, index) => entry === expected[index]);
}

function releaseCommitSubject(version) {
  return `chore(release): ${version} [skip ci]`;
}

function hasReleaseCommit(repositoryRoot, version) {
  const subjects = execFileSync("git", ["log", "--format=%s"], {
    cwd: repositoryRoot,
    encoding: "utf8",
  }).split("\n");
  return subjects.includes(releaseCommitSubject(version));
}

function trackedFileChanges(repositoryRoot) {
  const output = execFileSync(
    "git",
    ["diff", "--name-only", "-z", "HEAD", "--"],
    { cwd: repositoryRoot },
  );
  return output.toString("utf8").split("\0").filter(Boolean);
}

function restoreTrackedFiles(repositoryRoot) {
  const paths = trackedFileChanges(repositoryRoot);
  if (paths.length !== 0) {
    execFileSync(
      "git",
      ["restore", "--source=HEAD", "--staged", "--worktree", "--", ...paths],
      { cwd: repositoryRoot },
    );
  }
}

function defaultPackageRelease(repositoryRoot, version) {
  execFileSync(
    path.join(repositoryRoot, "scripts", "package-release.sh"),
    [version],
    {
      cwd: repositoryRoot,
      stdio: "inherit",
    },
  );
}

function prepareRelease(
  version,
  {
    expectedPreviousVersion,
    repositoryRoot = path.resolve(__dirname, ".."),
    packageRelease = defaultPackageRelease,
  } = {},
) {
  assertStableSemanticVersion(version, "The release version");

  const existingChanges = worktreeChanges(repositoryRoot);
  if (existingChanges.length !== 0) {
    throw new Error(
      `Release preparation requires a clean worktree; found: ${existingChanges.join(", ")}`,
    );
  }

  const projectSpecPath = path.join(repositoryRoot, versionAssetPaths[0]);
  const generatedProjectPath = path.join(
    repositoryRoot,
    versionAssetPaths[1],
  );
  const originalProjectSpec = readFileSync(projectSpecPath, "utf8");
  const originalGeneratedProject = readFileSync(generatedProjectPath, "utf8");
  const previousVersion = projectVersion(originalProjectSpec);
  const originalGeneratedVersions = generatedProjectVersions(
    originalGeneratedProject,
  );

  if (expectedPreviousVersion !== undefined) {
    assertStableSemanticVersion(
      expectedPreviousVersion,
      "The previous release version",
    );
    const isExpectedSource = previousVersion === expectedPreviousVersion;
    const isReleaseRetry = hasReleaseCommit(
      repositoryRoot,
      previousVersion,
    );
    if (!isExpectedSource && !isReleaseRetry) {
      throw new Error(
        `Source version ${previousVersion} does not match the previous release `
          + `${expectedPreviousVersion} or a prior bot release commit.`,
      );
    }
  }

  if (!originalGeneratedVersions.every((entry) => entry === previousVersion)) {
    throw new Error(
      "project.yml and the generated Xcode project disagree before release preparation.",
    );
  }

  try {
    writeAtomically(
      projectSpecPath,
      projectSpecWithVersion(originalProjectSpec, version),
    );
    packageRelease(repositoryRoot, version);

    const preparedProjectSpec = readFileSync(projectSpecPath, "utf8");
    const preparedGeneratedProject = readFileSync(
      generatedProjectPath,
      "utf8",
    );
    if (projectVersion(preparedProjectSpec) !== version) {
      throw new Error("Release preparation did not persist the source version.");
    }
    const preparedGeneratedVersions = generatedProjectVersions(
      preparedGeneratedProject,
    );
    if (
      preparedGeneratedVersions.length !== originalGeneratedVersions.length
      || !preparedGeneratedVersions.every((entry) => entry === version)
    ) {
      throw new Error(
        "Release preparation did not regenerate every Xcode project version.",
      );
    }
    if (
      preparedProjectSpec
        !== projectSpecWithVersion(originalProjectSpec, version)
      || preparedGeneratedProject
        !== generatedProjectWithVersion(originalGeneratedProject, version)
    ) {
      throw new Error(
        "Release preparation changed non-version source metadata.",
      );
    }

    const expectedChanges = previousVersion === version
      ? []
      : versionAssetPaths;
    const preparedChanges = worktreeChanges(repositoryRoot);
    if (!samePaths(preparedChanges, expectedChanges)) {
      throw new Error(
        "Release preparation changed unexpected worktree files: "
          + (preparedChanges.join(", ") || "none"),
      );
    }

    return {
      changed: previousVersion !== version,
      previousVersion,
      version,
    };
  } catch (error) {
    try {
      restoreTrackedFiles(repositoryRoot);
    } catch (rollbackError) {
      error.message += ` Rollback failed: ${rollbackError.message}`;
    }
    throw error;
  }
}

if (require.main === module) {
  const [version, expectedPreviousVersion, ...extraArguments] =
    process.argv.slice(2);
  if (!version || extraArguments.length !== 0) {
    console.error(
      "Usage: prepare-release.cjs <major.minor.patch> [previous-version]",
    );
    process.exitCode = 64;
  } else {
    try {
      const result = prepareRelease(version, { expectedPreviousVersion });
      const action = result.changed ? "Updated" : "Verified";
      console.log(`${action} source version ${result.version}.`);
    } catch (error) {
      console.error(`Release preparation failed: ${error.message}`);
      process.exitCode = 65;
    }
  }
}

module.exports = {
  generatedProjectWithVersion,
  generatedProjectVersions,
  prepareRelease,
  projectSpecWithVersion,
  projectVersion,
};
