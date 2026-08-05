const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");
const {
  chmodSync,
  mkdirSync,
  readFileSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync, spawnSync } = require("node:child_process");
const test = require("node:test");

const repositoryRoot = path.resolve(__dirname, "..");
const releaseConfigPath = path.join(repositoryRoot, "release.config.cjs");
const {
  generatedProjectWithVersion,
  generatedProjectVersions,
  prepareRelease,
  projectSpecWithVersion,
  projectVersion,
} = require(path.join(repositoryRoot, "scripts", "prepare-release.cjs"));

function loadReleaseConfig(signingMode) {
  const environmentName = "ROSTERWREN_SIGNING_MODE";
  const previousValue = process.env[environmentName];
  const previouslyPresent = Object.hasOwn(process.env, environmentName);
  if (signingMode === undefined) {
    delete process.env[environmentName];
  } else {
    process.env[environmentName] = signingMode;
  }
  delete require.cache[require.resolve(releaseConfigPath)];

  try {
    return require(releaseConfigPath);
  } finally {
    delete require.cache[require.resolve(releaseConfigPath)];
    if (previouslyPresent) {
      process.env[environmentName] = previousValue;
    } else {
      delete process.env[environmentName];
    }
  }
}

const releaseConfig = loadReleaseConfig();
const releaseWorkflow = readFileSync(
  path.join(repositoryRoot, ".github", "workflows", "release.yml"),
  "utf8",
);
const projectSpec = readFileSync(
  path.join(repositoryRoot, "project.yml"),
  "utf8",
);
const generatedProject = readFileSync(
  path.join(repositoryRoot, "RosterWren.xcodeproj", "project.pbxproj"),
  "utf8",
);
const sourceInfoPlist = readFileSync(
  path.join(repositoryRoot, "RosterWren", "Info.plist"),
  "utf8",
);
const configuredSourceVersion = projectVersion(projectSpec);
const packageScript = path.join(
  repositoryRoot,
  "scripts",
  "package-release.sh",
);
const signingScript = path.join(
  repositoryRoot,
  "scripts",
  "configure-release-signing.sh",
);
const pluginEntries = new Map(
  releaseConfig.plugins.map((plugin) => (
    Array.isArray(plugin) ? [plugin[0], plugin[1]] : [plugin, {}]
  )),
);
const analyzerOptions = pluginEntries.get("@semantic-release/commit-analyzer");
const notesOptions = pluginEntries.get(
  "@semantic-release/release-notes-generator",
);

async function releaseType(message) {
  const { analyzeCommits } = await import("@semantic-release/commit-analyzer");
  return analyzeCommits(
    analyzerOptions,
    {
      commits: [{ hash: "0123456789abcdef", message }],
      cwd: repositoryRoot,
      logger: {
        log() {},
      },
    },
  );
}

async function releaseNotes(messages) {
  const { generateNotes } = await import(
    "@semantic-release/release-notes-generator"
  );
  const commits = messages.map((message, index) => ({
    hash: `${index + 1}`.padStart(40, "0"),
    message,
  }));

  return generateNotes(
    notesOptions,
    {
      commits,
      cwd: repositoryRoot,
      lastRelease: {
        gitHead: "0".repeat(40),
        gitTag: "v0.1.0",
      },
      nextRelease: {
        gitHead: commits.at(-1).hash,
        gitTag: "v0.2.0",
        version: "0.2.0",
      },
      options: {
        repositoryUrl: "https://github.com/culpen90/RosterWren.git",
      },
    },
  );
}

test("release configuration publishes the complete macOS artifact set", () => {
  assert.deepEqual(releaseConfig.branches, ["main"]);
  assert.equal(releaseConfig.tagFormat, "v${version}");
  assert.deepEqual(
    releaseConfig.plugins.map((plugin) => (
      Array.isArray(plugin) ? plugin[0] : plugin
    )),
    [
      "@semantic-release/commit-analyzer",
      "@semantic-release/release-notes-generator",
      "@semantic-release/github",
      "@semantic-release/exec",
      "@semantic-release/git",
    ],
  );
  assert.deepEqual(notesOptions, analyzerOptions);

  const execOptions = pluginEntries.get("@semantic-release/exec");
  assert.equal(
    execOptions.prepareCmd,
    "node ./scripts/prepare-release.cjs ${nextRelease.version} ${lastRelease.version}",
  );
  assert.equal(
    execOptions.successCmd,
    "./scripts/publish-release-draft.sh ${nextRelease.gitTag} dist ${nextRelease.gitHead}",
  );

  const gitOptions = pluginEntries.get("@semantic-release/git");
  assert.deepEqual(
    gitOptions.assets,
    [
      "project.yml",
      "RosterWren.xcodeproj/project.pbxproj",
    ],
  );
  assert.equal(
    gitOptions.message,
    "chore(release): ${nextRelease.version} [skip ci]",
  );

  const githubOptions = pluginEntries.get("@semantic-release/github");
  assert.deepEqual(
    githubOptions.assets.map(({ path: assetPath }) => assetPath),
    [
      "dist/RosterWren-*-macOS-universal.dmg",
      "dist/RosterWren-*-macOS-universal.zip",
      "dist/RosterWren-*-dSYMs.zip",
      "dist/RosterWren-*-SHA256SUMS.txt",
    ],
  );
  assert.equal(githubOptions.draftRelease, true);
  assert.equal(githubOptions.successCommentCondition, false);
  assert.equal(githubOptions.failCommentCondition, false);
  assert.equal(githubOptions.releasedLabels, false);
  assert.match(
    githubOptions.releaseBodyTemplate,
    /<%= nextRelease\.notes %>/,
  );
  assert.match(
    githubOptions.releaseBodyTemplate,
    /<!-- rosterwren-distribution-start -->/,
  );
  assert.match(
    githubOptions.releaseBodyTemplate,
    /<!-- rosterwren-distribution-end -->/,
  );
});

test("ad-hoc opt-in is visibly labeled in release notes", () => {
  const adHocConfig = loadReleaseConfig("adhoc");
  const githubPlugin = adHocConfig.plugins.find((plugin) => (
    Array.isArray(plugin) && plugin[0] === "@semantic-release/github"
  ));
  assert(githubPlugin);
  assert.match(githubPlugin[1].releaseBodyTemplate, /\[!WARNING\]/);
  assert.match(githubPlugin[1].releaseBodyTemplate, /not Apple-notarized/);
});

test("Conventional Commits map to the intended release levels", async () => {
  assert.equal(await releaseType("fix: repair roster export"), "patch");
  assert.equal(await releaseType("perf: reduce capture work"), "patch");
  assert.equal(
    await releaseType(
      "revert: feat: add export\n\nThis reverts commit 0123456789abcdef.",
    ),
    "patch",
  );
  assert.equal(await releaseType("feat: add CSV export"), "minor");
  assert.equal(await releaseType("feat!: replace the roster format"), "major");
  assert.equal(
    await releaseType(
      "chore: reorganize internals\n\nBREAKING CHANGE: remove the old format",
    ),
    "major",
  );
});

test("non-product commits do not publish releases", async () => {
  for (const message of [
    "build: update build tooling",
    "chore: maintain dependencies",
    "ci: configure automation",
    "docs: clarify installation",
    "refactor: reorganize helpers",
    "style: format sources",
    "test: cover roster capture",
  ]) {
    assert.equal(await releaseType(message), null, message);
  }
});

test("generated release notes include product changes", async () => {
  const notes = await releaseNotes([
    "feat(export): add JSON output (#12)",
    "fix(capture): retain late participants",
    "docs: clarify installation",
  ]);

  assert.match(notes, /### Features/);
  assert.match(notes, /\*\*export:\*\* add JSON output/);
  assert.match(notes, /### Bug Fixes/);
  assert.match(notes, /\*\*capture:\*\* retain late participants/);
  assert.doesNotMatch(notes, /clarify installation/);
});

test("workflow guards publication and supplies the correct token", () => {
  assert.match(releaseWorkflow, /runs-on: macos-26/);
  assert.match(
    releaseWorkflow,
    /DEVELOPER_DIR: \/Applications\/Xcode_26\.6\.app\/Contents\/Developer/,
  );
  assert.match(releaseWorkflow, /queue: max/);
  assert.match(releaseWorkflow, /fetch-depth: 0/);
  assert.match(releaseWorkflow, /permissions:\n      contents: write/);
  assert.match(releaseWorkflow, /INITIAL_RELEASE_VERSION: 0\.1\.0/);
  assert.doesNotMatch(releaseWorkflow, /steps\.reconcile\.outputs\.reconciled/);
  const reconciliationScript = readFileSync(
    path.join(repositoryRoot, "scripts", "reconcile-releases.sh"),
    "utf8",
  );
  assert.match(reconciliationScript, /worktree add/);
  assert.match(reconciliationScript, /refusing to mutate published release assets/);
  assert.match(reconciliationScript, /publish-release-draft\.sh/);

  const publishStep = releaseWorkflow.match(
    /      - name: Build and publish the semantic release\n[\s\S]*?(?=\n      - name: Remove temporary signing credentials)/,
  );
  assert(publishStep, "Could not find the Semantic Release workflow step.");
  assert.match(
    publishStep[0],
    /GITHUB_TOKEN: \$\{\{ secrets\.GITHUB_TOKEN \}\}/,
  );
  assert.doesNotMatch(publishStep[0], /GH_TOKEN:/);
});

test("Xcode source version metadata is valid and aligned", () => {
  assert.match(
    configuredSourceVersion,
    /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/,
  );
  assert.match(projectSpec, /CURRENT_PROJECT_VERSION: "1"/);
  assert(
    generatedProjectVersions(generatedProject).every(
      (version) => version === configuredSourceVersion,
    ),
  );
  assert.match(
    projectSpec,
    /CFBundleShortVersionString: "\$\(MARKETING_VERSION\)"/,
  );
  assert.match(
    projectSpec,
    /CFBundleVersion: "\$\(CURRENT_PROJECT_VERSION\)"/,
  );
  assert.match(
    sourceInfoPlist,
    /<string>\$\(MARKETING_VERSION\)<\/string>/,
  );
  assert.match(
    sourceInfoPlist,
    /<string>\$\(CURRENT_PROJECT_VERSION\)<\/string>/,
  );
});

test("release preparation persists the version and fails closed", () => {
  const temporaryDirectory = mkdtempSync(
    path.join(os.tmpdir(), "rosterwren-version-test-"),
  );
  try {
    const testRepository = path.join(temporaryDirectory, "repository");
    const generatedProjectDirectory = path.join(
      testRepository,
      "RosterWren.xcodeproj",
    );
    mkdirSync(testRepository);
    mkdirSync(generatedProjectDirectory);
    writeFileSync(path.join(testRepository, "project.yml"), projectSpec);
    writeFileSync(
      path.join(generatedProjectDirectory, "project.pbxproj"),
      generatedProject,
    );
    writeFileSync(
      path.join(testRepository, "unexpected.txt"),
      "original contents\n",
    );

    execFileSync("git", ["init", "-b", "main"], { cwd: testRepository });
    execFileSync("git", ["config", "user.name", "Release Test"], {
      cwd: testRepository,
    });
    execFileSync("git", ["config", "user.email", "release@example.invalid"], {
      cwd: testRepository,
    });
    execFileSync("git", ["add", "."], { cwd: testRepository });
    execFileSync(
      "git",
      [
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-m",
        "test: add version fixtures",
      ],
      { cwd: testRepository },
    );

    const [major, minor, patchVersion] = configuredSourceVersion
      .split(".")
      .map(Number);
    const nextVersion = `${major}.${minor}.${patchVersion + 1}`;
    const generateProject = (repository, version) => {
      assert.equal(
        projectVersion(
          readFileSync(path.join(repository, "project.yml"), "utf8"),
        ),
        version,
      );
      const generatedPath = path.join(
        repository,
        "RosterWren.xcodeproj",
        "project.pbxproj",
      );
      const contents = readFileSync(generatedPath, "utf8");
      writeFileSync(
        generatedPath,
        generatedProjectWithVersion(contents, version),
      );
    };

    const prepared = prepareRelease(nextVersion, {
      expectedPreviousVersion: configuredSourceVersion,
      repositoryRoot: testRepository,
      packageRelease: generateProject,
    });
    assert.deepEqual(prepared, {
      changed: true,
      previousVersion: configuredSourceVersion,
      version: nextVersion,
    });
    assert.equal(
      projectVersion(
        readFileSync(path.join(testRepository, "project.yml"), "utf8"),
      ),
      nextVersion,
    );
    assert(
      generatedProjectVersions(
        readFileSync(
          path.join(generatedProjectDirectory, "project.pbxproj"),
          "utf8",
        ),
      ).every((version) => version === nextVersion),
    );
    assert.deepEqual(
      execFileSync("git", ["diff", "--name-only"], {
        cwd: testRepository,
        encoding: "utf8",
      }).trim().split("\n").sort(),
      [
        "RosterWren.xcodeproj/project.pbxproj",
        "project.yml",
      ],
    );

    execFileSync("git", ["add", "."], { cwd: testRepository });
    execFileSync(
      "git",
      [
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-m",
        `chore(release): ${nextVersion} [skip ci]`,
      ],
      { cwd: testRepository },
    );
    assert.deepEqual(
      prepareRelease(nextVersion, {
        expectedPreviousVersion: configuredSourceVersion,
        repositoryRoot: testRepository,
        packageRelease: generateProject,
      }),
      {
        changed: false,
        previousVersion: nextVersion,
        version: nextVersion,
      },
    );

    execFileSync(
      "git",
      [
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--amend",
        "-m",
        "feat: manually bump source version",
      ],
      { cwd: testRepository },
    );
    let driftPackagingStarted = false;
    assert.throws(
      () => prepareRelease(nextVersion, {
        expectedPreviousVersion: configuredSourceVersion,
        repositoryRoot: testRepository,
        packageRelease() {
          driftPackagingStarted = true;
        },
      }),
      /does not match the previous release/,
    );
    assert.equal(driftPackagingStarted, false);

    const failedVersion = `${major}.${minor}.${patchVersion + 2}`;
    assert.throws(
      () => prepareRelease(failedVersion, {
        expectedPreviousVersion: nextVersion,
        repositoryRoot: testRepository,
        packageRelease() {
          throw new Error("simulated packaging failure");
        },
      }),
      /simulated packaging failure/,
    );
    assert.equal(
      projectVersion(
        readFileSync(path.join(testRepository, "project.yml"), "utf8"),
      ),
      nextVersion,
    );
    assert.equal(
      execFileSync("git", ["status", "--porcelain"], {
        cwd: testRepository,
        encoding: "utf8",
      }),
      "",
    );

    assert.throws(
      () => prepareRelease(failedVersion, {
        expectedPreviousVersion: nextVersion,
        repositoryRoot: testRepository,
        packageRelease(repository, version) {
          generateProject(repository, version);
          const generatedPath = path.join(
            repository,
            "RosterWren.xcodeproj",
            "project.pbxproj",
          );
          writeFileSync(
            generatedPath,
            `${readFileSync(generatedPath, "utf8")}\n// unexpected setting\n`,
          );
        },
      }),
      /non-version source metadata/,
    );
    assert.equal(
      execFileSync("git", ["status", "--porcelain"], {
        cwd: testRepository,
        encoding: "utf8",
      }),
      "",
    );

    assert.throws(
      () => prepareRelease(failedVersion, {
        expectedPreviousVersion: nextVersion,
        repositoryRoot: testRepository,
        packageRelease(repository, version) {
          generateProject(repository, version);
          writeFileSync(
            path.join(repository, "unexpected.txt"),
            "changed during packaging\n",
          );
        },
      }),
      /unexpected worktree files/,
    );
    assert.equal(
      readFileSync(path.join(testRepository, "unexpected.txt"), "utf8"),
      "original contents\n",
    );
    assert.equal(
      execFileSync("git", ["status", "--porcelain"], {
        cwd: testRepository,
        encoding: "utf8",
      }),
      "",
    );

    const untrackedSource = path.join(testRepository, "Untracked.swift");
    writeFileSync(untrackedSource, "struct UntrackedReleaseSource {}\n");
    let packagingStarted = false;
    assert.throws(
      () => prepareRelease(failedVersion, {
        expectedPreviousVersion: nextVersion,
        repositoryRoot: testRepository,
        packageRelease() {
          packagingStarted = true;
        },
      }),
      /clean worktree/,
    );
    assert.equal(packagingStarted, false);
    rmSync(untrackedSource);

    assert.throws(
      () => projectSpecWithVersion(projectSpec, "1.02.3"),
      /stable major\.minor\.patch/,
    );
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("package script rejects invalid release versions before building", () => {
  const result = spawnSync(packageScript, ["1.02.3"], {
    cwd: repositoryRoot,
    encoding: "utf8",
  });
  assert.equal(result.status, 64);
  assert.match(result.stderr, /major\.minor\.patch/);
});

test("signing setup fails closed and requires explicit ad-hoc opt-in", () => {
  const temporaryDirectory = mkdtempSync(
    path.join(os.tmpdir(), "rosterwren-signing-test-"),
  );
  try {
    const githubEnvironment = path.join(temporaryDirectory, "github-env");
    const emptyEnvironment = {
      ...process.env,
      GITHUB_ENV: githubEnvironment,
      MACOS_CERTIFICATE_P12_BASE64: "",
      MACOS_CERTIFICATE_PASSWORD: "",
      MACOS_SIGNING_IDENTITY: "",
      APPLE_API_KEY_P8_BASE64: "",
      APPLE_API_KEY_ID: "",
      APPLE_API_ISSUER_ID: "",
      ALLOW_ADHOC_RELEASES: "",
    };
    const absent = spawnSync(signingScript, [], {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: emptyEnvironment,
    });
    assert.equal(absent.status, 78);
    assert.match(absent.stderr, /signing secrets are absent/i);

    const optedIn = spawnSync(signingScript, [], {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: {
        ...emptyEnvironment,
        ALLOW_ADHOC_RELEASES: "true",
      },
    });
    assert.equal(optedIn.status, 0, optedIn.stderr);
    assert.equal(
      readFileSync(githubEnvironment, "utf8"),
      "ROSTERWREN_SIGNING_MODE=adhoc\n",
    );

    const partial = spawnSync(signingScript, [], {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: {
        ...emptyEnvironment,
        MACOS_SIGNING_IDENTITY: "Developer ID Application: Example (TEAMID)",
      },
    });
    assert.equal(partial.status, 78);
    assert.match(partial.stderr, /incomplete/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("local packaging derives its default version from project metadata", () => {
  const result = spawnSync(
    path.join(repositoryRoot, "scripts", "current-version.sh"),
    [],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
    },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), configuredSourceVersion);
});

test("release reconciliation rebuilds the exact tag and fails closed", () => {
  const temporaryDirectory = mkdtempSync(
    path.join(os.tmpdir(), "rosterwren-reconcile-test-"),
  );
  try {
    const testRepository = path.join(temporaryDirectory, "repository");
    const remoteRepository = path.join(temporaryDirectory, "remote.git");
    const scriptsDirectory = path.join(testRepository, "scripts");
    const fakeBin = path.join(temporaryDirectory, "bin");
    const publishRecord = path.join(temporaryDirectory, "publish-record");
    const githubRecord = path.join(temporaryDirectory, "github-record");
    const fakeReleaseBody = path.join(temporaryDirectory, "release-body.md");
    mkdirSync(testRepository);
    mkdirSync(scriptsDirectory);
    mkdirSync(fakeBin);

    execFileSync("git", ["init", "--bare", remoteRepository]);
    execFileSync("git", ["init", "-b", "main"], { cwd: testRepository });
    execFileSync("git", ["config", "user.name", "Release Test"], {
      cwd: testRepository,
    });
    execFileSync("git", ["config", "user.email", "release@example.invalid"], {
      cwd: testRepository,
    });
    execFileSync("git", ["remote", "add", "origin", remoteRepository], {
      cwd: testRepository,
    });

    const reconcileScript = path.join(scriptsDirectory, "reconcile-releases.sh");
    writeFileSync(
      reconcileScript,
      readFileSync(
        path.join(repositoryRoot, "scripts", "reconcile-releases.sh"),
        "utf8",
      ),
    );
    const fakePackage = path.join(scriptsDirectory, "package-release.sh");
    writeFileSync(
      fakePackage,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "version=\"$1\"",
        "commit=\"$(git rev-parse HEAD)\"",
        "mkdir -p dist",
        "for suffix in macOS-universal.dmg macOS-universal.zip dSYMs.zip SHA256SUMS.txt; do",
        "  printf '%s\\n' \"$commit\" > \"dist/RosterWren-$version-$suffix\"",
        "done",
      ].join("\n"),
    );
    const fakePublisher = path.join(
      scriptsDirectory,
      "publish-release-draft.sh",
    );
    writeFileSync(
      fakePublisher,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "tag=\"$1\"",
        "artifact_directory=\"$2\"",
        "expected_commit=\"$3\"",
        "version=\"${tag#v}\"",
        "built_commit=\"$(tr -d '\\n' < \"$artifact_directory/RosterWren-$version-macOS-universal.dmg\")\"",
        "[[ \"$built_commit\" == \"$expected_commit\" ]]",
        "printf '%s\\t%s\\t%s\\n' \"$tag\" \"$built_commit\" \"$expected_commit\" > \"$RECONCILE_RECORD\"",
      ].join("\n"),
    );
    const fakeGitHub = path.join(fakeBin, "gh");
    writeFileSync(
      fakeGitHub,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "case \"${1:-} ${2:-}\" in",
        "  'repo view')",
        "    printf '%s\\n' 'example/RosterWren'",
        "    ;;",
        "  'release view')",
        "    if [[ \"${FAKE_RELEASE_STATE:-missing}\" == published-incomplete ]]; then",
        "      if [[ \"$*\" == *isDraft* && \"$*\" != *assets* ]]; then",
        "        printf '%s\\n' false",
        "      elif [[ \"$*\" == *isImmutable* ]]; then",
        "        printf '%s\\n' true",
        "      else",
        "        printf '%s\\n' 'RosterWren-0.2.0-macOS-universal.dmg'",
        "      fi",
        "      exit 0",
        "    fi",
        "    if [[ \"${FAKE_RELEASE_STATE:-missing}\" == published-mutable ]]; then",
        "      if [[ \"$*\" == *isDraft* && \"$*\" != *assets* ]]; then",
        "        printf '%s\\n' false",
        "      elif [[ \"$*\" == *isImmutable* ]]; then",
        "        printf '%s\\n' false",
        "      else",
        "        printf '%s\\n' 'RosterWren-0.2.0-macOS-universal.dmg'",
        "        printf '%s\\n' 'RosterWren-0.2.0-macOS-universal.zip'",
        "        printf '%s\\n' 'RosterWren-0.2.0-dSYMs.zip'",
        "        printf '%s\\n' 'RosterWren-0.2.0-SHA256SUMS.txt'",
        "      fi",
        "      exit 0",
        "    fi",
        "    if [[ \"${FAKE_RELEASE_STATE:-missing}\" == draft-initial ]]; then",
        "      if [[ \"$*\" == *body* ]]; then",
        "        cat \"$FAKE_RELEASE_BODY\"",
        "      elif [[ \"$*\" == *targetCommitish* ]]; then",
        "        printf '%s\\n' \"$FAKE_DRAFT_TARGET\"",
        "      elif [[ \"$*\" == *isDraft* && \"$*\" != *assets* ]]; then",
        "        printf '%s\\n' true",
        "      fi",
        "      exit 0",
        "    fi",
        "    exit 1",
        "    ;;",
        "  'release create')",
        "    printf '%s\\n' \"$*\" > \"$GH_RECORD\"",
        "    ;;",
        "  'release upload')",
        "    printf '%s\\n' \"$*\" > \"$GH_RECORD\"",
        "    ;;",
        "  'release edit')",
        "    previous=''",
        "    for argument in \"$@\"; do",
        "      if [[ \"$previous\" == --notes-file ]]; then",
        "        cp \"$argument\" \"$FAKE_RELEASE_BODY\"",
        "        break",
        "      fi",
        "      previous=\"$argument\"",
        "    done",
        "    printf '%s\\n' \"$*\" > \"$GH_RECORD\"",
        "    ;;",
        "  *)",
        "    exit 1",
        "    ;;",
        "esac",
      ].join("\n"),
    );
    for (const executable of [reconcileScript, fakePackage, fakePublisher, fakeGitHub]) {
      chmodSync(executable, 0o755);
    }

    writeFileSync(path.join(testRepository, "README.md"), "tagged source\n");
    writeFileSync(
      fakeReleaseBody,
      [
        "Recovered release notes.",
        "",
        "<!-- rosterwren-distribution-start -->",
        "> [!WARNING]",
        "> This release uses an ad-hoc development signature and is not Apple-notarized.",
        "<!-- rosterwren-distribution-end -->",
        "",
      ].join("\n"),
    );
    execFileSync("git", ["add", "."], { cwd: testRepository });
    execFileSync("git", [
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-m",
      "feat: tagged source",
    ], {
      cwd: testRepository,
    });
    execFileSync("git", ["tag", "--no-sign", "v0.2.0"], {
      cwd: testRepository,
    });
    const taggedCommit = execFileSync(
      "git",
      ["rev-parse", "v0.2.0^{commit}"],
      { cwd: testRepository, encoding: "utf8" },
    ).trim();

    writeFileSync(path.join(testRepository, "later.txt"), "newer main source\n");
    execFileSync("git", ["add", "."], { cwd: testRepository });
    execFileSync("git", [
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-m",
      "fix: later source",
    ], {
      cwd: testRepository,
    });
    execFileSync("git", ["push", "-u", "origin", "main", "--tags"], {
      cwd: testRepository,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const currentCommit = execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: testRepository,
      encoding: "utf8",
    }).trim();
    assert.notEqual(currentCommit, taggedCommit);

    const baseEnvironment = {
      ...process.env,
      PATH: `${fakeBin}:${process.env.PATH}`,
      GITHUB_REPOSITORY: "example/RosterWren",
      GITHUB_SHA: currentCommit,
      GH_RECORD: githubRecord,
      FAKE_RELEASE_BODY: fakeReleaseBody,
      RECONCILE_RECORD: publishRecord,
      ROSTERWREN_SIGNING_MODE: "developer-id",
    };
    execFileSync(reconcileScript, [], {
      cwd: testRepository,
      env: baseEnvironment,
      stdio: "pipe",
    });

    const [publishedTag, builtCommit, expectedCommit] = readFileSync(
      publishRecord,
      "utf8",
    ).trim().split("\t");
    assert.equal(publishedTag, "v0.2.0");
    assert.equal(builtCommit, taggedCommit);
    assert.equal(expectedCommit, taggedCommit);
    assert.match(readFileSync(githubRecord, "utf8"), /source-0\.2\.0\/dist/);

    const publishedIncomplete = spawnSync(reconcileScript, [], {
      cwd: testRepository,
      encoding: "utf8",
      env: {
        ...baseEnvironment,
        FAKE_RELEASE_STATE: "published-incomplete",
      },
    });
    assert.equal(publishedIncomplete.status, 65);
    assert.match(publishedIncomplete.stderr, /public but incomplete/);

    const publishedMutable = spawnSync(reconcileScript, [], {
      cwd: testRepository,
      encoding: "utf8",
      env: {
        ...baseEnvironment,
        FAKE_RELEASE_STATE: "published-mutable",
      },
    });
    assert.equal(publishedMutable.status, 65);
    assert.match(publishedMutable.stderr, /public but mutable/);

    execFileSync("git", ["tag", "--delete", "v0.2.0"], {
      cwd: testRepository,
      stdio: ["ignore", "pipe", "pipe"],
    });
    execFileSync("git", ["push", "origin", ":refs/tags/v0.2.0"], {
      cwd: testRepository,
      stdio: ["ignore", "pipe", "pipe"],
    });
    execFileSync(reconcileScript, [], {
      cwd: testRepository,
      env: {
        ...baseEnvironment,
        FAKE_RELEASE_STATE: "draft-initial",
        FAKE_DRAFT_TARGET: taggedCommit,
      },
      stdio: "pipe",
    });
    const [recoveredTag, recoveredBuild, recoveredTarget] = readFileSync(
      publishRecord,
      "utf8",
    ).trim().split("\t");
    assert.equal(recoveredTag, "v0.1.0");
    assert.equal(recoveredBuild, taggedCommit);
    assert.equal(recoveredTarget, taggedCommit);
    assert.match(readFileSync(githubRecord, "utf8"), /release upload v0\.1\.0/);
    assert.match(
      readFileSync(fakeReleaseBody, "utf8"),
      /The downloadable app is Developer ID signed and Apple-notarized\./,
    );
    assert.doesNotMatch(readFileSync(fakeReleaseBody, "utf8"), /\[!WARNING\]/);

    execFileSync("git", ["tag", "--no-sign", "v0.3.0-beta.1"], {
      cwd: testRepository,
    });
    const unexpectedTag = spawnSync(reconcileScript, [], {
      cwd: testRepository,
      encoding: "utf8",
      env: baseEnvironment,
    });
    assert.equal(unexpectedTag.status, 65);
    assert.match(unexpectedTag.stderr, /Unexpected v-prefixed tag/);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});

test("draft publication verifies remote digests before publishing", () => {
  const temporaryDirectory = mkdtempSync(
    path.join(os.tmpdir(), "rosterwren-publish-test-"),
  );
  try {
    const artifactDirectory = path.join(temporaryDirectory, "dist");
    const fakeBin = path.join(temporaryDirectory, "bin");
    const draftState = path.join(temporaryDirectory, "draft-state");
    const releaseBody = path.join(temporaryDirectory, "release-body.md");
    mkdirSync(artifactDirectory);
    mkdirSync(fakeBin);

    const version = "1.2.3";
    const binaryNames = [
      `RosterWren-${version}-macOS-universal.dmg`,
      `RosterWren-${version}-macOS-universal.zip`,
      `RosterWren-${version}-dSYMs.zip`,
    ];
    const digestByName = new Map();
    for (const [index, assetName] of binaryNames.entries()) {
      const contents = `asset-${index + 1}\n`;
      writeFileSync(path.join(artifactDirectory, assetName), contents);
      digestByName.set(
        assetName,
        createHash("sha256").update(contents).digest("hex"),
      );
    }
    const checksumName = `RosterWren-${version}-SHA256SUMS.txt`;
    const checksumContents = binaryNames.map((assetName) => (
      `${digestByName.get(assetName)}  ${assetName}`
    )).join("\n") + "\n";
    writeFileSync(
      path.join(artifactDirectory, checksumName),
      checksumContents,
    );
    digestByName.set(
      checksumName,
      createHash("sha256").update(checksumContents).digest("hex"),
    );

    const assetRows = [...digestByName.entries()].map(([name, digest]) => (
      `${name}\tsha256:${digest}`
    ));
    const expectedCommit = "a".repeat(40);
    const fakeGitHub = path.join(fakeBin, "gh");
    writeFileSync(
      fakeGitHub,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "if [[ \"${1:-} ${2:-}\" == 'release view' ]]; then",
        "  if [[ \"$*\" == *body* ]]; then",
        "    cat \"$RELEASE_BODY\"",
        "  elif [[ \"$*\" == *isImmutable* ]]; then",
        "    printf '%s\\n' true",
        "  elif [[ \"$*\" == *isDraft* ]]; then",
        "    cat \"$DRAFT_STATE\"",
        "  elif [[ \"$*\" == *targetCommitish* ]]; then",
        `    printf '%s\\n' '${expectedCommit}'`,
        "  elif [[ \"${BAD_ASSET_DIGEST:-false}\" == true ]]; then",
        `    printf '%s\\n' '${binaryNames[0]}\tsha256:${"0".repeat(64)}'`,
        ...assetRows.slice(1).map((row) => `    printf '%s\\n' '${row}'`),
        "  else",
        ...assetRows.map((row) => `    printf '%s\\n' '${row}'`),
        "  fi",
        "elif [[ \"${1:-} ${2:-}\" == 'release edit' ]]; then",
        "  printf '%s\\n' false > \"$DRAFT_STATE\"",
        "else",
        "  exit 1",
        "fi",
      ].join("\n"),
    );
    const fakeGit = path.join(fakeBin, "git");
    writeFileSync(
      fakeGit,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "case \"${1:-}\" in",
        "  rev-parse)",
        "    if [[ \"$*\" == *--verify* && \"$(cat \"$DRAFT_STATE\")\" == true ]]; then",
        "      exit 1",
        "    fi",
        `    printf '%s\\n' '${expectedCommit}'`,
        "    ;;",
        "  fetch)",
        "    ;;",
        "  *)",
        "    exit 1",
        "    ;;",
        "esac",
      ].join("\n"),
    );
    chmodSync(fakeGitHub, 0o755);
    chmodSync(fakeGit, 0o755);

    const developerIdBody = [
      "Release notes.",
      "",
      "<!-- rosterwren-distribution-start -->",
      "The downloadable app is Developer ID signed and Apple-notarized.",
      "<!-- rosterwren-distribution-end -->",
      "",
    ].join("\n");
    writeFileSync(releaseBody, developerIdBody);

    const publisher = path.join(
      repositoryRoot,
      "scripts",
      "publish-release-draft.sh",
    );
    const baseEnvironment = {
      ...process.env,
      PATH: `${fakeBin}:${process.env.PATH}`,
      DRAFT_STATE: draftState,
      GH_TOKEN: "test-token",
      GITHUB_REPOSITORY: "example/RosterWren",
      RELEASE_BODY: releaseBody,
      ROSTERWREN_SIGNING_MODE: "developer-id",
    };
    writeFileSync(draftState, "true\n");
    const published = spawnSync(
      publisher,
      [`v${version}`, artifactDirectory, expectedCommit],
      {
        cwd: repositoryRoot,
        encoding: "utf8",
        env: baseEnvironment,
      },
    );
    assert.equal(published.status, 0, published.stderr);
    assert.equal(readFileSync(draftState, "utf8"), "false\n");

    writeFileSync(draftState, "true\n");
    writeFileSync(
      releaseBody,
      developerIdBody.replace(
        "The downloadable app is Developer ID signed and Apple-notarized.",
        "> [!WARNING]\n> This release uses an ad-hoc development signature and is not Apple-notarized.",
      ),
    );
    const mismatchedSigningNotice = spawnSync(
      publisher,
      [`v${version}`, artifactDirectory, expectedCommit],
      {
        cwd: repositoryRoot,
        encoding: "utf8",
        env: baseEnvironment,
      },
    );
    assert.equal(mismatchedSigningNotice.status, 65);
    assert.match(mismatchedSigningNotice.stderr, /signing mode/);
    assert.equal(readFileSync(draftState, "utf8"), "true\n");

    writeFileSync(releaseBody, developerIdBody);
    const mismatch = spawnSync(
      publisher,
      [`v${version}`, artifactDirectory, expectedCommit],
      {
        cwd: repositoryRoot,
        encoding: "utf8",
        env: {
          ...baseEnvironment,
          BAD_ASSET_DIGEST: "true",
        },
      },
    );
    assert.equal(mismatch.status, 70);
    assert.match(mismatch.stderr, /digest does not match/);
    assert.equal(readFileSync(draftState, "utf8"), "true\n");
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
});
